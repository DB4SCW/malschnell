# Malschnell
## What does this program do?
If you are running special callsigns on WSJT-X using the WavelogGate connector to send your QSOs to Wavelog, you might have come across this situation:

You are working on a special callsign and you see a rare station you like to have on your own callsign as well. 
So you just switch your WSJT-X to your call and work them again. 

This is also the origin of the name: "malschnell" in German means "just quickly" as in "I'll work them quickly before continuing".

So... you want to work them quickly, but...

WavelogGate will, of course, still send this ADIF package to the API endpoint for your special event call and will refuse to do so.

This programm hooks itself into the default (not the secondary) UDP server of WSJT-X. You can specify the desired station callsign for the next QSO package that will arrive. This will get stored in a sqlite database with the modified station callsign.

This allows you the collect multiple QSOs for your own (or any other) call over the course of your session without switching WavelogGate.

Once you are ready, switch Waveloggate to the correct API endpoint and station id and choose the output option to get all those collected QSOs from the database and send them over to WavelogGate and (finally) to Wavelog.

## How do I use this?

### Mac or Linux

Make sure all dependencies are there. It's just one, the sqlite3 gem: ```gem install sqlite3```

After that, just run ```ruby malschnell.rb```. 

This will create the database and the default config file in the working directory and start the collection or output process as you choose.

### Windows
Install ruby and do the same as Mac or Linux, or just double-click the malschnell.exe from this repository. 

This should work even without ruby installed. If windows queries you if you want to grant malschnell.exe network or file access, please accept.
