require "open-uri"

if __FILE__ == $0
  begin
  	# This line causes error, if during downloading a file pressing ctrl-c to interrupt the script
  	`echo anything`

    puts "Getting a file .. waiting for ctrl-c"

		open("http://images.4chan.org/hr/src/1303644000146.jpg")

		puts "Downloaded"
  rescue Interrupt => e
    puts "Interrupted111"
  end
end

