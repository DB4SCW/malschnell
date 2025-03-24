require 'socket'
require 'sqlite3'
require 'yaml'
require 'ipaddr'
require 'net/http'
require 'json'
require 'uri'

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
VERBOSE_LOGGING  = config.fetch('VERBOSE_LOGGING', default_config['VERBOSE_LOGGING'])
WAVELOG_DIRECT   = config.fetch('WAVELOG_DIRECT', default_config['WAVELOG_DIRECT'])
WAVELOG_URL      = config.fetch('WAVELOG_URL', default_config['WAVELOG_URL'])
WAVELOG_DICT     = config.fetch('WAVELOG_DICT', default_config['WAVELOG_DICT'])

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

# handle package
def handle_incoming_adif_package(db, callsign, adif, sender_ip, sender_port, wavelog_url = "", waveloggate_mode = false, wavelog_dict = Hash.new)

  # just store package if waveloggate mode is inactive
  unless waveloggate_mode
    store_package(db, callsign, adif, sender_ip, sender_port, waveloggate_mode)
    return color_text("\nStored ADIF package for qso with #{partner_call} using callsign '#{call}' (from #{sender_ip}:#{sender_port}).", "green")
  end

  # store package if station callsign is not defined in config
  unless wavelog_dict.keys.include?()
    store_package(db, callsign, adif, sender_ip, sender_port, waveloggate_mode)
    return color_text("\nStored ADIF package for qso with #{partner_call} using UNKOWN callsign '#{call}' (from #{sender_ip}:#{sender_port}).", "yellow")
  end

  # store package if url is empty
  if wavelog_url == ""
    store_package(db, callsign, adif, sender_ip, sender_port, waveloggate_mode)
    return color_text("\nStored ADIF package for qso with #{partner_call} using callsign '#{call}' (from #{sender_ip}:#{sender_port}).", "green")
  end

  # load callsign config
  callsignconfig = wavelog_dict[callsign]

  # try to send data directly to wavelog
  result = send_to_wavelog(wavelog_url, callsignconfig["key"], callsignconfig["station_id"], adif)

  # if API is ok, return success, if not, store package for later
  if result == 201
    return color_text("\nSent ADIF package for qso with #{partner_call} using callsign '#{call}' to Wavelog.", "green")
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
  return responsecode if responsecode >= 400

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
  return 500

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

      # store both original and modified packages, plus original and new callsigns.
      puts handle_incoming_adif_package(db, call, adif, sender_ip, sender_port, WAVELOG_URL, WAVELOG_DIRECT, WAVELOG_DICT)

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
    if WAVELOG_DICT.keys.include?(selected_call) and WAVELOG_URL != ""
      
      # track if all packages are delivered ok
      allok = true

      # send of each package to wavelog directly
      packages.each do |id, pkg|
        response = send_to_wavelog(WAVELOG_URL, WAVELOG_DICT[selected_call]["key"], WAVELOG_DICT[selected_call]["station_id"], pkg)
        allok = false unless response == 201
        sleep 0.5  # slight delay between packets
      end

      # delete those packages only if all are ok
      delete_packages(db, selected_call) if allok
      
      # print result and resume
      puts color_text("Sent and removed stored packages for '#{selected_call}'.", "green")
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

            # proxy all received packages to defined ip and port
            if PROXY_PACKAGES
              proxy_send.send(data, 0, PROXY_TO_IP, PROXY_TO_PORT)
            end

            next unless data.include?("<adif_ver:")

            adif_start = data.index("<adif_ver:")
            adif = data[adif_start..-1]
            call = extract_station_callsign(adif) || "UNKNOWN"
            partner_call = extract_partner_callsign(adif) || "UNKNOWN"
            puts handle_incoming_adif_package(db, call, adif, sender_ip, sender_port, WAVELOG_URL, WAVELOG_DIRECT, WAVELOG_DICT)
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