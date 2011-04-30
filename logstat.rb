f = File.open("logs/log.txt_")
loaded = f.read.scan(/Download size (\d+) kb/)
loaded.flatten!.collect! {|x| x.to_i}

puts loaded.inject(:+).to_f	/ 1024.to_f / loaded.size.to_f
