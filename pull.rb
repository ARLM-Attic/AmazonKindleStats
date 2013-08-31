require "json"
require "yaml"
require "mechanize"
require "nokogiri"
require "typhoeus"
require "cgi"

# Only works for US Amazon for the time being
class Crawler
  PER_PAGE = 100
  CATEGORIES = {"fiona_ebook" => true}

  def initialize
    @mech = Mechanize.new do |c|
      c.redirect_ok = true
      c.follow_meta_refresh = true
      c.user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_8_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/30.0.1599.22 Safari/537.36"
    end
  end

  def login(username, password)
    page = @mech.get("https://www.amazon.com/ap/signin/180-8153124-1972456?_encoding=UTF8&_encoding=UTF8&openid.assoc_handle=usflex&openid.claimed_id=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select&openid.identity=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select&openid.mode=checkid_setup&openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0&openid.ns.pape=http%3A%2F%2Fspecs.openid.net%2Fextensions%2Fpape%2F1.0&openid.pape.max_auth_age=0&openid.return_to=https%3A%2F%2Fwww.amazon.com%2Fgp%2Fyourstore%2Fhome%3Fie%3DUTF8%26ref_%3Dgno_signin")

    form = page.form_with(:id => "ap_signin_form")
    form.email = username.strip
    form.password = password.strip

    form["ap_signin_existing_radio"] = "1"

    @page = @mech.submit(form)
    unless @page.title =~ /Recommended for You/i
      raise "Didn't seem to be able to authenticate, on '#{@page.title}' page"
    end

    @season_id = @page.body.match(/ue_sid='(.+)'/)[1]
  end

  def load_books
    book_data = []

    offset, per_page = 0, 100

    has_data = true
    while has_data do
      has_data = false

      puts "Loading books at offset #{offset}"

      page = @mech.post("https://www.amazon.com/gp/digital/fiona/manage/features/order-history/ajax/queryOwnership_refactored2.html", {
        :offset => offset,
        :count => per_page,
        :contentType => "all",
        :randomizer => Time.now.utc.to_i,
        :queryToken => 0,
        :isAjax => 1
      })

      res = JSON.parse(page.body)
      if res["isError"] != 0 or res["signInRequired"] != 0
        raise "Failed to load data #{res["error"]}"
      end

      break unless res["data"]["items"]
      res["data"]["items"].each do |item|
        has_data = true
        next unless CATEGORIES[item["category"]]
        next if item["author"] == "Amazon"

        book_data << {
          :author => CGI::unescapeHTML(item["author"] || item["authorOrPronunciation"] || ""),
          :title => CGI::unescapeHTML(item["title"] || item["titleOrPronunciation"] || ""),
          :asin => item["asin"],
          :ordered => Time.at(item["orderDateEpoch"]),
          :order_id => item["orderID"],
          :category => item["category"]
        }
      end

      offset += per_page
    end

    book_data
  end

  def load_pdocs
    book_data = []

    offset, per_page = 0, 100

    has_data = true
    while has_data do
      has_data = false

      puts "Loading personal documents at offset #{offset}"

      page = @mech.post("https://www.amazon.com/gp/digital/fiona/manage/features/order-history/ajax/queryPdocs.html", {
        :offset => offset,
        :count => per_page,
        :contentType => "Personal Documents",
        :randomizer => Time.now.utc.to_i,
        :queryToken => 0,
        :isAjax => 1
      })

      res = JSON.parse(page.body)
      if res["isError"] != 0 or res["signInRequired"] != 0
        raise "Failed to load data #{res["error"]}"
      end

      break unless res["data"]["items"]
      res["data"]["items"].each do |item|
        has_data = true

        # Parse date
        date, time = item["orderDateNumerical"].split("T", 2)
        date = date.split("-", 3)
        time = time.split(":", 3)

        book_data << {
          :author => CGI::unescapeHTML(item["author"] || ""),
          :title => CGI::unescapeHTML(item["title"] || ""),
          :asin => item["asin"],
          :ordered => Time.utc(date[0], date[1], date[2], time[0], time[1], time[2]),
          :order_id => item["asin"],
          :category => item["category"]
        }
      end

      offset += per_page
    end

    book_data
  end

  def load_all_books
    load_pdocs.concat(load_books)
  end

  def load_prices(books)
    books.each do |book|
      next unless book[:category] == "fiona_ebook"
      next if book[:order_price] and book[:offer_price]

      puts "Loading prices for #{book[:title]} by #{book[:author]}"

      page = @mech.post("https://www.amazon.com/gp/digital/fiona/manage/features/order-history/ajax/getExpandedInfo.html", {
        :sid => @season_id,
        :asin => book[:asin],
        :orderID => book[:order_id],
        :subscriptionID => 0,
        :isAjax => 1
      })

      res = JSON.parse(page.body.strip)

      book[:order_price] = res["orderPrice"].gsub(/[^\.0-9]+/, "").to_f
      book[:offer_price] = res["offerPrice"].gsub(/[^\.0-9]+/, "").to_f
      book[:currency] = res["offerPrice"][0, 1]
    end

    books
  end

  def load_pages(books)
    books.each do |book|
      next unless book[:category] == "fiona_ebook"
      next if book[:pages]

      puts "Loading pages for #{book[:title]} by #{book[:author]}"

      begin
        page = @mech.get("http://www.amazon.com/gp/product/#{book[:asin]}/ref=kinw_myk_ro_title")
      rescue Mechanize::ResponseCodeError => e

        puts "ERROR: #{e.message}"
        next
      end

      link = page.link_with(:id => "pageCountAvailable")
      if link
        book[:pages] = link.text.match(/([0-9]+)/)[1].to_i
      else
        match = page.body.match(/Print Length:(.+)<\/li>/i)
        book[:pages] = match[1].match(/([0-9]+)/)[1].to_i
      end
    end

    books
  end

  def dump_books(path, books)
    File.open(path, "w+") do |f|
      f.write(books.to_yaml)
    end
  end
end

crawler = Crawler.new
crawler.login(*File.read("/tmp/login").split(",", 2))

books = crawler.load_all_books
books = crawler.load_prices(books)
books = crawler.load_pages(books)
#books = crawler.load_progress(books)
crawler.dump_books("/tmp/books.yml", books)