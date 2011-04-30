require "rubygems"
require "open-uri"
require "RMagick"
require "nokogiri"
require "logger"

class ArtDownloaderd

  class RuntimeError < StandardError; end

  DESIRED_ZOOM = 2

  TILES_FOLDER = "tiles/"
  TILES_INFO_FOLDER = "tiles_info/"
  RESULT_FOLDER = "result/"
  LOG_FOLDER = "logs/"
  LOG_FILENAME = "log.txt"
  SUMMARY_FOLDER = "summary/"
  SUMMARY_FILENAME = "artworks.xml"

  def initialize
    Dir.mkdir(TILES_FOLDER) unless Dir.exist?(TILES_FOLDER)
    Dir.mkdir(TILES_INFO_FOLDER) unless Dir.exist?(TILES_INFO_FOLDER)
    Dir.mkdir(LOG_FOLDER) unless Dir.exist?(LOG_FOLDER)
    Dir.mkdir(SUMMARY_FOLDER) unless Dir.exist?(SUMMARY_FOLDER)
    Dir.mkdir(RESULT_FOLDER) unless Dir.exist?(RESULT_FOLDER)
    @log = Logger.new(log_path)
    @log.level = Logger::INFO
  end

  def download(url)
    @url = url
    verify_url!
    get_image_id
    downloading
  end

  def download_by_id(id)
    @iid = id
    downloading
  end

  def get_artworks_urls
    google_url = "http://www.googleartproject.com"
    begin
      html = open(google_url)
  	rescue
  		error "URL is unavailable"
    end
    artworks = Nokogiri::XML::Builder.new do |xml|
      xml.googleartproject {
        xml.museums {
        }
      }
    end
    f = File.open(summary_path, "wb") { |f| f.print artworks.to_xml }
    f = File.open(summary_path)
    artdoc = Nokogiri::XML(f)
    mdoc = Nokogiri::HTML(html)
    museums = mdoc.xpath("//li/@data-museum-url")

#   Parsing main google art project page
    museums.each {|museum|
      museum_url = google_url + museum.to_s
      root_museums = artdoc.at_css("museums")
      m = Nokogiri::XML::Node.new("museum", artdoc)
      m["museum_url"] = museum_url
      begin
        workshtml = open(museum_url)
  	  rescue
  		  error "URL is unavailable"
      end
      wdoc = Nokogiri::HTML(workshtml)
      li = wdoc.xpath("//div[@class='content sortable thumbnail-list']/ul/li")
      li.each {|l|
        params = {"data_thumbnail" => l.xpath("@data-thumbnail").to_s,
                  "art_url" => (google_url + l.xpath("a/@href").to_s),
                  "name" => l.xpath("a/strong").first.content,
                  "artist" => l.xpath("a/span").first.content}
        aw = Nokogiri::XML::Node.new("artwork", m)
        params.each_pair do |k, v|
          val = Nokogiri::XML::Node.new(k, aw)
          val.content = v
          aw.add_child(val)
        end
        m.add_child(aw)
      }
      root_museums.add_child(m)
    }
    File.open(summary_path,'wb') {|f| artdoc.write_xml_to f}
    @log.info("Created #{summary_path}")
    puts "Created #{summary_path}"
  end

  def get_all_artworks
    unless File.exists?(summary_path)
      get_artworks_urls
    end
    f = File.open(summary_path)
    doc = Nokogiri::XML(f)
    thumbs = doc.xpath("//data_thumbnail").children
    works_count = thumbs.size
    i = 0
    thumbs[0...works_count].each {|thumb|
      i += 1
      puts "Artwork #{i} of #{works_count}"
      @log.info("Artwork #{i} of #{works_count}")
      begin
        download_by_id(thumb.to_s)
      rescue ArtDownloader::RuntimeError => e
        @log.error("Error #{e.message}")
        puts "Error #{e.message}"
      rescue Interrupt
        @log.error("Interrupted")
        puts "Interrupted"
        break
      end
    }
  end

private

  def downloading
    get_tile_info
    @log.info("Start #{full_path}")
    puts "Start #{full_path}"
    if File.exists?(full_path)
      @log.warn("Already exists")
      puts "Already exists"
      return
    end
    get_tiles
    stitch_tiles
    delete_tiles
  end

  def verify_url!
  	unless @url =~ /\A(http:\/\/www\.googleartproject\.com\/museums)\/([a-z]+)\/([a-z\d\-%])+\z/i
      error "Please specify a Google Art Project URL"
    end
  end

  def get_image_id
  	begin
      @html = open(@url)
  	rescue
  		error "URL is unavailable"
    end
    doc = Nokogiri::HTML(@html)
    @iid = doc.xpath("/html/body/@data-thumbnail").to_s
    unless @iid
      error "Couldn't find an image at the page"
    end
  end

  def get_tile_info
    get_file(tile_info_url, tile_info_path)
    f = File.open(tile_info_path)
    doc = Nokogiri::XML(f)

    # Unfortunately some xml prodived by googleartproject
    # contains wrong full_pyramid_depth ;)
		@full_pyramid_depth = doc.xpath("//pyramid_level").size
    @zoom = [DESIRED_ZOOM, @full_pyramid_depth - 1].min
    @tile_width = doc.xpath("/TileInfo/@tile_width").to_s.to_i
    @tile_height = doc.xpath("/TileInfo/@tile_height").to_s.to_i

    node = doc.xpath("/TileInfo/pyramid_level[#{@zoom + 1}]")
    @num_tiles_x = node.xpath("@num_tiles_x").to_s.to_i
    @num_tiles_y = node.xpath("@num_tiles_y").to_s.to_i
    @empty_pels_x = node.xpath("@empty_pels_x").to_s.to_i
    @empty_pels_y = node.xpath("@empty_pels_y").to_s.to_i

    node_last = doc.xpath("/TileInfo/pyramid_level[last()]")
    @maximum_num_tiles_x = node_last.xpath("@num_tiles_x").to_s.to_i
    @maximum_num_tiles_y = node_last.xpath("@num_tiles_y").to_s.to_i
    @maximum_empty_pels_x = node_last.xpath("@empty_pels_x").to_s.to_i
    @maximum_empty_pels_y = node_last.xpath("@empty_pels_y").to_s.to_i

    @evaluable_width = @num_tiles_x * @tile_width - @empty_pels_x
    @evaluable_height = @num_tiles_y * @tile_height - @empty_pels_y
    @maximum_width = @maximum_num_tiles_x * @tile_width - @maximum_empty_pels_x
    @maximum_height = @maximum_num_tiles_y * @tile_height - @maximum_empty_pels_y
    f.close
  end

  def get_file(url, path)
    begin
      if File.exist?(path)
        return 0
      end
      data = open(url)
      File.open(path, "wb") { |f| f.print data.read }
      return File.size(path)
    rescue StandardError => e
      puts $!, "Warning: #{e.message}"
      return 0
    end
  end

  def get_tiles
    a = Time.now
    tiles_size = 0
    tiles_count = @num_tiles_x * @num_tiles_y
    print "Tiles count: #{tiles_count} "
    for y in 0...@num_tiles_y
      for x in 0...@num_tiles_x
        current_tile_number = x + y * @num_tiles_x + 1
        print "."
        url = tile_url(x, y)
        tile_size = get_file(url, tile_path(x, y))
        if tile_size > 0
          tiles_size += tile_size
        end
      end
    end
    puts
    time = Time.now - a
    dspeed = (tiles_size.to_f / 1024.to_f / time).round(0)
    dsize = (tiles_size.to_f / 1024.to_f).round(0)
    @log.info("Download size #{dsize} kb")
    @log.info("Download speed #{time} kb/s")
    @log.info("Download time #{time} s")
    puts "Download size #{dsize} kb"
    puts "Download speed #{dspeed} kb/s"
    puts "Download time #{time} s"
  end

  def stitch_tiles
  	a = Time.now
    tiles = []
    for y in 0...@num_tiles_y
      for x in 0...@num_tiles_x
        tiles.push(tile_path(x, y))
      end
    end
    ilist = Magick::ImageList.new(*tiles)
    num_x = @num_tiles_x
    num_y = @num_tiles_y

#   Joining images
    montage = ilist.montage do
      self.geometry = Magick::Geometry.new(512, 512, 0, 0)
      self.tile = Magick::Geometry.new(num_x, num_y)
    end
    cropped = montage.crop(0, 0, @evaluable_width, @evaluable_height, true)
    cropped.write(full_path) { self.quality = 95 }
    time = Time.now - a
    @log.info("Joining time #{time} s")
    puts "Joining time #{time} s"
    @log.info("Result file size #{(File.size(full_path).to_f / 1024.to_f).round(0)} kb")
    puts "Result file size #{(File.size(full_path).to_f / 1024.to_f).round(0)} kb"
  end

  def delete_tiles
    for y in 0...@num_tiles_y
      for x in 0...@num_tiles_x
        File.delete(tile_path(x, y))
      end
    end
  end

  def error(message)
    raise ArtDownloader::RuntimeError, "#{message} (#{@url})"
  end

  def tile_url(x, y)
    # The subdomain can seemingly be anything from lh3 to lh6.
    "http://lh5.ggpht.com/#{@iid}=x#{x}-y#{y}-z#{@zoom}"
  end

  def tile_info_url
    "http://lh5.ggpht.com/#{@iid}=g"
  end

  def tile_info_path
    TILES_INFO_FOLDER + "#{@iid[0,5]}=g.xml"
  end

  def tile_path(x, y)
    TILES_FOLDER + "#{@iid[0,5]}=z#{@zoom}-y#{y}-x#{x}.jpg"
  end

  def full_path
    RESULT_FOLDER + "#{@iid[0,5]}-full=z#{@zoom}.jpg"
  end

  def summary_path
    SUMMARY_FOLDER + SUMMARY_FILENAME
  end

  def log_path
    LOG_FOLDER + LOG_FILENAME
  end
end

if __FILE__ == $0
  ArtDownloader.new.get_all_artworks
end

__END__

