require 'socket'
require 'sqlite3'
require 'yaml'

# Default configuration values
default_config = {
  'WSJT_RX_PORT'    => 2237,
  'SEND_PORT'       => 2333,
  'BIND_IP'         => '0.0.0.0',
  'SEND_IP'         => '127.0.0.1',
  'DATABASE_NAME'   => 'packages.sqlite3',
  "DB_JOURNAL_MODE" => 'DELETE'
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

# create UDP sockets:
udp_recv = UDPSocket.new
udp_recv.bind(BIND_IP, WSJT_RX_PORT)

udp_send = UDPSocket.new

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

# replace the <station_callsign:...> field with the new callsign.
# this updates the field width to the length of new_callsign.
def replace_station_callsign(adif_text, new_callsign)
  adif_text.gsub(/<station_callsign:\d+>[^<]+/i) do |_match|
    "<station_callsign:#{new_callsign.length}>#{new_callsign}"
  end
end

# insert a qso record into the database.
def store_package(db, callsign, adif, sender_ip, sender_port)
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
  puts "\nSelect mode:"
  puts "  1) Input – capture and store NEXT ADIF package for rebroadcast later"
  puts "  2) Output – list stored packages & broadcast them"
  if $indefinite_mode_running
    puts "  3) Stop indefinite mode"
  else
    puts "  3) Indefinite Input Mode – start receiving packages indefinitely"
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
        store_other(db, data, sender_ip, sender_port)
        puts color_text("Received packet does not appear to be a valid ADIF package. Ignoring.", "yellow")
        next
      end

      # get adif start
      adif_start = data.index("<adif_ver:")
      
      # get original adif
      adif = data[adif_start..-1]

      # extract the original station_callsign (if present).
      call = extract_station_callsign(adif) || "UNKNOWN"

      # store both original and modified packages, plus original and new callsigns.
      store_package(db, call, adif, sender_ip, sender_port)

      # info about the package we just received
      puts color_text("Stored ADIF package for callsign '#{call}' (from #{sender_ip}:#{sender_port}).", "green")

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
    
    # print whats happening
    puts color_text("Sending #{packages.size} package(s) for '#{selected_call}' to #{SEND_IP}:#{SEND_PORT}...", "yellow")

    # rebroadcast each package
    packages.each do |id, pkg|
      udp_send.send(pkg, 0, SEND_IP, SEND_PORT)
      sleep 0.5  # slight delay between packets
    end

    # delete broadcasted packages from database
    delete_packages(db, selected_call)

    # print info message
    puts color_text("Sent and removed stored packages for '#{selected_call}'.", "green")

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

            unless data.include?("<adif_ver:")
              store_other(db, data, sender_ip, sender_port)
              print color_text("\nReceived packet does not appear to be a valid ADIF package. Ignoring.", "yellow")
              next
            end

            adif_start = data.index("<adif_ver:")
            adif = data[adif_start..-1]
            call = extract_station_callsign(adif) || "UNKNOWN"
            store_package(db, call, adif, sender_ip, sender_port)
            print color_text("\nStored ADIF package for callsign '#{call}' (from #{sender_ip}:#{sender_port}).", "green")
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
    puts color_text("Invalid choice. Please enter 1, 2, or 3.", "red")
  end
end

# close database
db.close

# close program
exit 0