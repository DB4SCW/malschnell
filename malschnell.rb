require 'socket'
require 'sqlite3'
require 'yaml'
require 'ipaddr'
require 'net/http'
require 'json'
require 'uri'
require 'openssl'
require 'rexml/document'
require 'thread'
# Default configuration values
default_config = {
  'WSJT_RX_PORT'    => 2237,
  'SEND_PORT'       => 2333,
  'BIND_IP'         => '0.0.0.0',
  'SEND_IP'         => '127.0.0.1',
  'DATABASE_NAME'   => 'packages.sqlite3',
  "DB_JOURNAL_MODE" => 'DELETE',
  "MULTICAST_GROUP" => '239.255.0.1',
  "PROXY_PACKAGES"  => false,
  "PROXY_TO_IP"     => '127.0.0.1',
  "PROXY_TO_PORT"   => 2237,
  "VERBOSE_LOGGING" => false,
  "QRZ_LOOKUP_ENABLED" => false,
  "QRZ_USERNAME" => '',
  "QRZ_PASSWORD" => '',
  "QRZ_AGENT" => 'malschnell/1.0',
  "QRZ_TIMEOUT" => 10,
  "WAVELOG_DIRECT"  => false,
  "WAVELOG_URL"     => '',
  "WAVELOG_DICT"    => Hash.new
}
# config handling
config_file = 'config.yml'

unless File.exist?(config_file)
  File.open(config_file, 'w') do |file|
    file.write(default_config.to_yaml)
  end
  puts "Configuration file created with default values."
end

# load config
config = YAML.load_file(config_file)
# Set configuration constants with values from the config file or defaults
WSJT_RX_PORT     = config.fetch('WSJT_RX_PORT', default_config['WSJT_RX_PORT'])
SEND_PORT        = config.fetch('SEND_PORT', default_config['SEND_PORT'])
BIND_IP          = config.fetch('BIND_IP', default_config['BIND_IP'])
SEND_IP          = config.fetch('SEND_IP', default_config['SEND_IP'])
DB_FILE          = config.fetch('DATABASE_NAME', default_config['DATABASE_NAME'])
DB_JOURNAL_MODE  = config.fetch('DB_JOURNAL_MODE', default_config['DB_JOURNAL_MODE'])
MULTICAST_GROUP  = config.fetch('MULTICAST_GROUP', default_config['MULTICAST_GROUP'])
PROXY_PACKAGES   = config.fetch('PROXY_PACKAGES', default_config['PROXY_PACKAGES'])
PROXY_TO_IP      = config.fetch('PROXY_TO_IP', default_config['PROXY_TO_IP'])
PROXY_TO_PORT    = config.fetch('PROXY_TO_PORT', default_config['PROXY_TO_PORT'])
VERBOSE_LOGGING    = config.fetch('VERBOSE_LOGGING', default_config['VERBOSE_LOGGING'])
QRZ_LOOKUP_ENABLED = config.fetch('QRZ_LOOKUP_ENABLED', default_config['QRZ_LOOKUP_ENABLED'])
QRZ_USERNAME       = config.fetch('QRZ_USERNAME', default_config['QRZ_USERNAME'])
QRZ_PASSWORD       = config.fetch('QRZ_PASSWORD', default_config['QRZ_PASSWORD'])
QRZ_AGENT          = config.fetch('QRZ_AGENT', default_config['QRZ_AGENT'])
QRZ_TIMEOUT        = config.fetch('QRZ_TIMEOUT', default_config['QRZ_TIMEOUT'])
WAVELOG_DIRECT     = config.fetch('WAVELOG_DIRECT', default_config['WAVELOG_DIRECT'])
WAVELOG_URL      = config.fetch('WAVELOG_URL', default_config['WAVELOG_URL'])
WAVELOG_DICT     = config.fetch('WAVELOG_DICT', default_config['WAVELOG_DICT'])
# QRZ XML client with session reuse and an in-memory callsign cache.
class QrzClient
  ENDPOINT = URI('https://xmldata.qrz.com/xml/current/').freeze

  def initialize(enabled:, username:, password:, agent:, timeout:, verbose: false)
    @requested = enabled
    @username = username.to_s.strip
    @password = password.to_s
    @agent = agent.to_s.strip.empty? ? 'malschnell/1.0' : agent.to_s.strip
    @timeout = [timeout.to_i, 1].max
    @verbose = verbose
    @session_key = nil
    @cache = {}
    @mutex = Mutex.new

    if @requested && !configured?
      warn '[QRZ] Lookup is enabled, but QRZ_USERNAME or QRZ_PASSWORD is empty. QRZ enrichment is disabled.'
    end
  end

  def enabled?
    @requested && configured?
  end

  def lookup(callsign)
    return nil unless enabled?

    normalized_call = callsign.to_s.strip.upcase
    return nil if normalized_call.empty? || normalized_call == 'UNKNOWN'

    @mutex.synchronize do
      return @cache[normalized_call] if @cache.key?(normalized_call)

      result, cacheable = lookup_uncached(normalized_call)
      @cache[normalized_call] = result if cacheable
      result
    end
  rescue StandardError => e
    warn "[QRZ] Lookup for #{normalized_call || callsign} failed: #{e.message}"
    nil
  end

  private

  def configured?
    !@username.empty? && !@password.empty?
  end

  def lookup_uncached(callsign)
    2.times do |attempt|
      login! if @session_key.nil?

      document = request_xml('s' => @session_key, 'callsign' => callsign)
      root = document.root
      session = direct_child(root, 'Session')
      returned_key = element_text(direct_child(session, 'Key'))
      @session_key = returned_key unless returned_key.empty?

      callsign_node = direct_child(root, 'Callsign')
      if callsign_node
        first_name = element_text(direct_child(callsign_node, 'fname'))
        last_name = element_text(direct_child(callsign_node, 'name'))
        full_name = [first_name, last_name].reject(&:empty?).join(' ').strip
        full_name = element_text(direct_child(callsign_node, 'name_fmt')) if full_name.empty?
        qth = element_text(direct_child(callsign_node, 'addr2'))

        if full_name.empty? && qth.empty?
          message = session_message(session)
          warn "[QRZ] #{callsign}: no NAME or QTH data returned#{message.empty? ? '' : " (#{message})"}."
          return [nil, true]
        end

        puts "[QRZ] #{callsign}: NAME='#{full_name}', QTH='#{qth}'" if @verbose
        return [{ name: full_name, qth: qth }, true]
      end

      error = session_message(session)

      # QRZ omits the Key element when a session is no longer valid.
      if returned_key.empty? && attempt.zero?
        @session_key = nil
        next
      end

      warn "[QRZ] #{callsign}: #{error.empty? ? 'lookup returned no callsign data' : error}."
      return [nil, error.match?(/not found/i)]
    end

    [nil, false]
  end

  def login!
    document = request_xml(
      'username' => @username,
      'password' => @password,
      'agent' => @agent
    )

    session = direct_child(document.root, 'Session')
    key = element_text(direct_child(session, 'Key'))
    error = session_message(session)
    raise "login failed#{error.empty? ? '' : ": #{error}"}" if key.empty?

    @session_key = key
    puts '[QRZ] Session established.' if @verbose
  end

  def request_xml(parameters)
    request = Net::HTTP::Post.new(ENDPOINT.request_uri)
    request['Accept'] = 'application/xml,text/xml'
    request['User-Agent'] = @agent
    request.set_form_data(parameters)

    http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = @timeout
    http.read_timeout = @timeout

    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      raise "HTTP #{response.code} #{response.message}"
    end

    REXML::Document.new(response.body)
  rescue REXML::ParseException => e
    raise "invalid XML response: #{e.message}"
  end

  def direct_child(element, name)
    return nil unless element

    element.elements.each do |child|
      return child if child.name.casecmp(name).zero?
    end

    nil
  end

  def element_text(element)
    element&.text.to_s.strip
  end

  def session_message(session)
    error = element_text(direct_child(session, 'Error'))
    return error unless error.empty?

    element_text(direct_child(session, 'Message'))
  end
end

# create UDP receive  sockets:
udp_recv = UDPSocket.new
udp_recv.bind(BIND_IP, WSJT_RX_PORT)

# Join the multicast group.
multicast_addr = MULTICAST_GROUP
membership = IPAddr.new(multicast_addr).hton + IPAddr.new(BIND_IP).hton
udp_recv.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, membership)

# create UDP send socket(s)
udp_send = UDPSocket.new

proxy_send = nil
if(PROXY_PACKAGES)
  proxy_send = UDPSocket.new
end

qrz_client = QrzClient.new(
  enabled: QRZ_LOOKUP_ENABLED,
  username: QRZ_USERNAME,
  password: QRZ_PASSWORD,
  agent: QRZ_AGENT,
  timeout: QRZ_TIMEOUT,
  verbose: VERBOSE_LOGGING
)

# initialize the SQLite database.
db = SQLite3::Database.new(DB_FILE)
# set journaling mode
db.execute "PRAGMA journal_mode = #{DB_JOURNAL_MODE};"

# create table if it doesn't exist.
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS packages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    callsign TEXT,
    adif TEXT,
    ip TEXT,
    port INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
SQL
# creates "other" table
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS other (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content TEXT,
    ip TEXT,
    port INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
SQL

# a helper method to extract the original station_callsign value from the ADIF text.
def extract_station_callsign(adif_text)
  if match = adif_text.match(/<station_callsign:\d+>([^<]+)/i)
    match[1].strip
  else
    nil
  end
end
# a helper method to extract the partner callsign value from the ADIF text.
def extract_partner_callsign(adif_text)
  if match = adif_text.match(/<call:\d+>([^<]+)/i)
    match[1].strip
  else
    nil
  end
end
# sanitize text before writing it into an ADIF value.
def sanitize_adif_value(value)
  value.to_s
       .encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
       .gsub(/[\u0000-\u001f\u007f<>]/, ' ')
       .gsub(/\s+/, ' ')
       .strip
end

# update an existing ADIF field or insert it immediately before <EOR>.
def upsert_adif_field(adif_text, field_name, value)
  clean_value = sanitize_adif_value(value)
  return adif_text if clean_value.empty?

  field = "<#{field_name}:#{clean_value.length}>#{clean_value}"
  field_pattern = /<#{Regexp.escape(field_name)}:\d+(?::[^>]*)?>[^<]*/i

  if adif_text.match?(field_pattern)
    return adif_text.sub(field_pattern) do |existing_field|
      trailing_whitespace = existing_field[/\s+\z/] || ''
      "#{field}#{trailing_whitespace}"
    end
  end

  eor_match = adif_text.match(/<eor>/i)
  return "#{adif_text.rstrip} #{field} <eor>" unless eor_match

  insertion_point = eor_match.begin(0)
  prefix = insertion_point.positive? && adif_text[insertion_point - 1] !~ /\s/ ? ' ' : ''
  enriched = adif_text.dup
  enriched.insert(insertion_point, "#{prefix}#{field} ")
  enriched
end

# add NAME and QTH from QRZ; return the original ADIF if lookup fails.
def enrich_adif_from_qrz(adif, partner_call, qrz_client, verbose = false)
  return adif unless qrz_client&.enabled?

  qrz_data = qrz_client.lookup(partner_call)
  return adif unless qrz_data

  enriched_adif = upsert_adif_field(adif, 'NAME', qrz_data[:name])
  enriched_adif = upsert_adif_field(enriched_adif, 'QTH', qrz_data[:qth])
  puts "[QRZ] Added NAME/QTH to ADIF for #{partner_call}." if verbose && enriched_adif != adif
  enriched_adif
end

# replace the <station_callsign:...> field with the new callsign.
# this updates the field width to the length of new_callsign.
def replace_station_callsign(adif_text, new_callsign)
  adif_text.gsub(/<station_callsign:\d+>[^<]+/i) do |_match|
    "<station_callsign:#{new_callsign.length}>#{new_callsign}"
  end
end
# insert a qso record into the database.
def store_package(db, callsign, adif, sender_ip, sender_port, waveloggate_mode = false)
  db.execute("INSERT INTO packages (callsign, adif, ip, port) VALUES (?, ?, ?, ?)", [callsign, adif, sender_ip, sender_port])
end

# insert an 'other' record into the database.
def store_other(db, content, sender_ip, sender_port)
  db.execute("INSERT INTO other (content, ip, port) VALUES (?, ?, ?)", [content, sender_ip, sender_port])
end
# get distinct new_callsign values with count of stored packages.
def list_callsigns(db)
  db.execute("SELECT callsign, COUNT(*) FROM packages GROUP BY callsign")
end

# retrieve packages for a given new_callsign, ordered by created datetime.
def retrieve_packages(db, callsign)
  db.execute("SELECT id, adif FROM packages WHERE callsign = ? ORDER BY created_at ASC", [callsign])
end
# delete packages for a given new_callsign.
def delete_packages(db, callsign)
  db.execute("DELETE FROM packages WHERE callsign = ?", [callsign])
end

def delete_one_package(db, id)
  db.execute("DELETE FROM packages WHERE id = ?", [id])
end
# handle package
def handle_incoming_adif_package(db, callsign, partner_call, adif, sender_ip, sender_port, wavelog_url = "", waveloggate_mode = false, wavelog_dict = Hash.new)

  # just store package if waveloggate mode is inactive
  unless waveloggate_mode
    store_package(db, callsign, adif, sender_ip, sender_port, waveloggate_mode)
    return color_text("\nStored ADIF package for qso with #{partner_call} using callsign '#{callsign}' (from #{sender_ip}:#{sender_port}).", "green")
  end
  # store package if station callsign is not defined in config
  unless wavelog_dict.keys.include?(callsign)
    store_package(db, callsign, adif, sender_ip, sender_port, waveloggate_mode)
    return color_text("\nStored ADIF package for qso with #{partner_call} using UNKOWN callsign '#{callsign}' (from #{sender_ip}:#{sender_port}).", "yellow")
  end
  # store package if url is empty
  if wavelog_url == ""
    store_package(db, callsign, adif, sender_ip, sender_port, waveloggate_mode)
    return color_text("\nStored ADIF package for qso with #{partner_call} using callsign '#{callsign}' (from #{sender_ip}:#{sender_port}).", "green")
  end

  # load callsign config
  callsignconfig = wavelog_dict[callsign]

  # try to send data directly to wavelog
  result = send_to_wavelog(wavelog_url, callsignconfig["key"], callsignconfig["station_id"], adif)
  # if API is ok, return success, if not, store package for later
  if result == 201
    return color_text("\nSent ADIF package for qso with #{partner_call} using callsign '#{callsign}' to Wavelog.", "green")
  else
    store_package(db, callsign, adif, sender_ip, sender_port, waveloggate_mode)
    return color_text("\nStored ADIF package for qso with #{partner_call} because of API failure.", "yellow")
  end
end
# try to send the package directly to Wavelog
def send_to_wavelog(urlraw, api_key, station_id, adif)

  # Define the API endpoint
  url = URI(urlraw.rstrip.chomp("/") + "/index.php/api/qso")

  # Define the request payload
  payload = {
    key: api_key,
    station_profile_id: station_id.to_s,
    type: "adif",
    string: adif
  }.to_json
  # Create the HTTP request
  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = (url.scheme == "https") # Enable SSL if needed
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE

  request = Net::HTTP::Post.new(url)
  request["Content-Type"] = "application/json"
  request["Accept"] = "application/json"
  request.body = payload

  # Execute the request
  begin
    response = http.request(request)
  rescue
    return 500
  end

  # get http response code
  responsecode = response.code
  # return error code if error code is present
  return responsecode if responsecode.to_i >= 400

  # parse return code
  begin
    json_response = JSON.parse(response.body)
    status =  json_response['status']
  rescue JSON::ParserError
    return 500
  end

  # return success
  return 201 if status == "created"

  # return error
  return 418

end
# colors the text for console output
def color_text(text, color)
  colorcode = case color
    when "yellow" then "\e[33m"
    when "green" then "\e[32m"
    when "blue" then "\e[34m"
    when "red" then "\e[31m"
    when "black" then "\e[30m"
    when "cyan" then "\e[36m"
    else "\e[0m"
  end

  # color the text before setting the color back to default
  colorcode + text + "\e[0m"
end

# Global variables for indefinite mode
indefinite_thread = nil
$indefinite_mode_running = false
# main menu loop.
loop do

  # print instructions to screen
  if WAVELOG_DIRECT
    puts "\nSelect mode (Wavelog Direct Mode):"
  else
    puts "\nSelect mode (WavelogGate Mode):"
  end
  puts "  1) Input – capture and handle NEXT ADIF package"
  puts "  2) Output – list stored packages & broadcast them"
  if $indefinite_mode_running
    puts "  3) Stop indefinite mode"
  else
    if PROXY_PACKAGES
      puts "  3) Indefinite Input Mode – start rcv+proxy packages indefinitely"
    else
      puts "  3) Indefinite Input Mode – start receiving packages indefinitely"
    end
  end
  puts "  4) Exit"
  print "Choice: "
  # get the users choice
  choice = gets.chomp.strip

  # react to the choice
  case choice
  when '1'

    # mode 1: Input Mode
    # enter waiting mode
    puts "Waiting for the next ADIF package on port #{WSJT_RX_PORT}..."

    # iterate as long as an adif package is found
    notadifpackage = true
    while notadifpackage do

      # wait for package
      data, sender_info = udp_recv.recvfrom(4096)
      sender_ip = sender_info[3]
      sender_port = sender_info[1]
      # check if package is ADIF QSO, if not wait for next package
      unless data.include?("<adif_ver:")
        store_other(db, data, sender_ip, sender_port) if VERBOSE_LOGGING
        puts color_text("Received packet does not appear to be a valid ADIF package. Ignoring.", "yellow") if VERBOSE_LOGGING
        next
      end

      # get adif start
      adif_start = data.index("<adif_ver:")

      # get original adif
      adif = data[adif_start..-1]
      # extract the original station_callsign (if present).
      call = extract_station_callsign(adif) || "UNKNOWN"

      # extract the partner callsign
      partner_call = extract_partner_callsign(adif) || "UNKNOWN"

      # enrich the ADIF before it is stored or sent.
      adif = enrich_adif_from_qrz(adif, partner_call, qrz_client, VERBOSE_LOGGING)

      # store both original and modified packages, plus original and new callsigns.
      puts handle_incoming_adif_package(db, call, partner_call, adif, sender_ip, sender_port, WAVELOG_URL, WAVELOG_DIRECT, WAVELOG_DICT)
      # set the flag because we found an adif package
      notadifpackage = false

    end


  when '2'
    # Mode 2: Output Mode

    # get count of stored UDP packages
    rows = list_callsigns(db)

    # return if none were found
    if rows.empty?
      puts color_text("\nNo stored packages in the database.", "cyan")
      next
    end
    # print the calls to screen:
    puts "\nStored new callsigns and package counts:"
    rows.each_with_index do |(call, count), index|
      puts "  #{index + 1}) #{call} – #{count} package(s)"
    end

    # get the call the user wants to trigger the broadcast for
    print "\nEnter the number of a callsign to send its packages (or leave blank to return): "
    selection = gets.chomp.strip

    # next iteration for empty input
    next if selection.empty?
    # check validity of selection and go to next interation
    index = selection.to_i - 1
    if index < 0 || index >= rows.size
      puts color_text("Invalid selection. Index " + (index + 1).to_s + " does not exist.", "red")
      next
    end

    # get call according to index
    selected_call = rows[index][0]

    # retrieve packages from database
    packages = retrieve_packages(db, selected_call)
    # send to wavelog or send to udp
    if WAVELOG_DICT.keys.include?(selected_call) and WAVELOG_URL != "" and WAVELOG_DIRECT

      # track if all packages are delivered ok
      allok = true
      # send of each package to wavelog directly
      packages.each do |id, pkg|
        response = send_to_wavelog(WAVELOG_URL, WAVELOG_DICT[selected_call]["key"], WAVELOG_DICT[selected_call]["station_id"], pkg)
        unless response == 201
          allok = false
        else
          delete_one_package(db, id)
        end
        sleep 0.5  # slight delay between packets
      end

      # print result and resume
      if allok
        puts color_text("Sent and removed stored packages for '#{selected_call}'.", "green")
      else
        puts color_text("One or more packages for '#{selected_call}' could not be sent successfully.", "yellow")
      end
      next
    else

      # print whats happening
      puts color_text("Sending #{packages.size} package(s) for '#{selected_call}' to #{SEND_IP}:#{SEND_PORT}...", "yellow")
      # rebroadcast each package to udp socket
      packages.each do |id, pkg|
        udp_send.send(pkg, 0, SEND_IP, SEND_PORT)
        sleep 0.5  # slight delay between packets
      end

      # delete broadcasted packages from database
      delete_packages(db, selected_call)

      # print info message
      puts color_text("Sent and removed stored packages for '#{selected_call}'.", "green")

    end
  when '3'
    # Indefinite mode

    if $indefinite_mode_running
      # Stop indefinite mode
      $indefinite_mode_running = false
      indefinite_thread.join if indefinite_thread
      indefinite_thread = nil
      puts color_text("Indefinite receiving mode stopped.", "green")
    else
      # start indefinite mode in a separate thread
      $indefinite_mode_running = true
      indefinite_thread = Thread.new do
        while $indefinite_mode_running
          # use IO.select to avoid blocking indefinitely so we can check the flag periodically.
          ready = IO.select([udp_recv], nil, nil, 1)
          if ready
            data, sender_info = udp_recv.recvfrom(4096)
            sender_ip = sender_info[3]
            sender_port = sender_info[1]
            # proxy non-ADIF WSJT-X packets unchanged.
            unless data.include?("<adif_ver:")
              proxy_send.send(data, 0, PROXY_TO_IP, PROXY_TO_PORT) if PROXY_PACKAGES
              next
            end

            adif_start = data.index("<adif_ver:")
            adif = data[adif_start..-1]
            call = extract_station_callsign(adif) || "UNKNOWN"
            partner_call = extract_partner_callsign(adif) || "UNKNOWN"
            adif = enrich_adif_from_qrz(adif, partner_call, qrz_client, VERBOSE_LOGGING)

            # keep the WSJT-X packet prefix and proxy the enriched ADIF body.
            if PROXY_PACKAGES
              enriched_packet = data[0...adif_start] + adif
              proxy_send.send(enriched_packet, 0, PROXY_TO_IP, PROXY_TO_PORT)
            end

            puts handle_incoming_adif_package(db, call, partner_call, adif, sender_ip, sender_port, WAVELOG_URL, WAVELOG_DIRECT, WAVELOG_DICT)
          end
        end
      end
      puts color_text("Indefinite receiving mode started in background.", "green")
    end
  when '4'

    # exiting the program
    puts color_text("Exiting.", "green")
    break

  else
    # inform about invalid choice
    puts color_text("Invalid choice. Please enter 1, 2, 3 or 4.", "red")
  end
end
# close database
db.close

# close program
exit 0
