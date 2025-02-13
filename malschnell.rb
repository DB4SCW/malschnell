require 'socket'
require 'sqlite3'
require 'yaml'

# Default configuration values
default_config = {
  'WSJT_RX_PORT' => 2237,
  'SEND_PORT'    => 2333,
  'BIND_IP'      => '0.0.0.0',
  'SEND_IP'      => '127.0.0.1'
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
WSJT_RX_PORT = config.fetch('WSJT_RX_PORT', default_config['WSJT_RX_PORT'])
SEND_PORT    = config.fetch('SEND_PORT', default_config['SEND_PORT'])
BIND_IP      = config.fetch('BIND_IP', default_config['BIND_IP'])
SEND_IP      = config.fetch('SEND_IP', default_config['SEND_IP'])

# create UDP sockets:
udp_recv = UDPSocket.new
udp_recv.bind(BIND_IP, WSJT_RX_PORT)

udp_send = UDPSocket.new

# initialize the SQLite database.
DB_FILE = "packages.db"
db = SQLite3::Database.new(DB_FILE)

# create table if it doesn't exist.
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS packages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    new_callsign TEXT,
    original_callsign TEXT,
    original_adif TEXT,
    modified_adif TEXT,
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

# replace the <station_callsign:...> field with the new callsign.
# this updates the field width to the length of new_callsign.
def replace_station_callsign(adif_text, new_callsign)
  adif_text.gsub(/<station_callsign:\d+>[^<]+/i) do |_match|
    "<station_callsign:#{new_callsign.length}>#{new_callsign}"
  end
end

# insert a record into the database.
def store_package(db, new_callsign, original_callsign, original_adif, modified_adif)
  db.execute("INSERT INTO packages (new_callsign, original_callsign, original_adif, modified_adif) VALUES (?, ?, ?, ?)",
             [new_callsign, original_callsign, original_adif, modified_adif])
end

# get distinct new_callsign values with count of stored packages.
def list_callsigns(db)
  db.execute("SELECT new_callsign, COUNT(*) FROM packages GROUP BY new_callsign")
end

# retrieve packages for a given new_callsign, ordered by created datetime.
def retrieve_packages(db, new_callsign)
  db.execute("SELECT id, modified_adif FROM packages WHERE new_callsign = ? ORDER BY created_at ASC", [new_callsign])
end

# delete packages for a given new_callsign.
def delete_packages(db, new_callsign)
  db.execute("DELETE FROM packages WHERE new_callsign = ?", [new_callsign])
end

# main menu loop.
loop do
  
  # print instructions to screen
  puts "\nSelect mode:"
  puts "  1) Input – capture, modify and store next ADIF package for rebroadcast later"
  puts "  2) Output – list stored packages & broadcast them"
  puts "  3) Exit"
  print "Choice: "

  # get the users choice
  choice = gets.chomp.strip

  # react to the choice
  case choice
  when '1'
    
    # mode 1: Input Mode
    # print instructions
    print "\nEnter the callsign for which the next logged wsjt-x QSO \nshould be rebroadcasted later"
    print "\n(or leave blank to return to main menu): "
    
    # get callsign input
    user_callsign = gets.chomp.strip.upcase
    
    # check for abort condition
    if user_callsign.empty?
      puts "Returning to main menu..."
      next
    end

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
        puts "Received packet from #{sender_ip}:#{sender_port} does not appear to be a valid ADIF package. Ignoring."
        next
      end

      # get adif start
      adif_start = data.index("<adif_ver:")
      
      # get original adif
      original_adif = data[adif_start..-1]

      # extract the original station_callsign (if present).
      orig_call = extract_station_callsign(original_adif) || "UNKNOWN"

      # replace the station_callsign field with the user-supplied callsign.
      modified_adif = replace_station_callsign(original_adif, user_callsign)

      # store both original and modified packages, plus original and new callsigns.
      store_package(db, user_callsign, orig_call, original_adif, modified_adif)

      # info about the package we just received
      puts "Stored ADIF package for new callsign '#{user_callsign}' (original station_callsign: '#{orig_call}') from #{sender_ip}:#{sender_port}."

      # set the flag because we found an adif package
      notadifpackage = false
      
    end
    

  when '2'
    # Mode 2: Output Mode

    # get count of stored UDP packages
    rows = list_callsigns(db)
    
    # return if none were found
    if rows.empty?
      puts "\nNo stored packages in the database."
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
      puts "Invalid selection."
      next
    end

    # get call according to index
    selected_call = rows[index][0]
    
    # retrieve packages from database
    packages = retrieve_packages(db, selected_call)
    
    # print whats happening
    puts "Sending #{packages.size} package(s) for '#{selected_call}' to #{SEND_IP}:#{SEND_PORT}..."

    # rebroadcast each package
    packages.each do |id, pkg|
      udp_send.send(pkg, 0, SEND_IP, SEND_PORT)
      sleep 0.5  # slight delay between packets
    end

    # delete broadcasted packages from database
    delete_packages(db, selected_call)

    # print info message
    puts "Sent and removed packages for '#{selected_call}'."

  when '3'
    
    # exiting the program
    puts "Exiting."
    break

  else
    # inform about invalid choice
    puts "Invalid choice. Please enter 1, 2, or 3."
  end
end

# close database
db.close

# close program
exit 0