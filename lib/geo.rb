require "geo/version"

module Geo
  # CS constants
  MAXMIND_ZIPPED_URL = "http://geolite.maxmind.com/download/geoip/database/GeoLite2-City-CSV.zip"
  FILES_FOLDER = File.expand_path('../db', __FILE__)
  MAXMIND_DB_FN = File.join(FILES_FOLDER, "GeoLite2-City-Locations-en.csv")
  COUNTRIES_FN = File.join(FILES_FOLDER, "countries.yml")

  @countries, @states, @cities = [{}, {}, {}]

  def self.update_maxmind
    require "open-uri"
    require "zip"

    # get zipped file
    f_zipped = open(MAXMIND_ZIPPED_URL)

    # unzip file:
    # recursively searches for "GeoLite2-City-Locations-en"
    Zip::File.open(f_zipped) do |zip_file|
      zip_file.each do |entry|
        if entry.name["GeoLite2-City-Locations-en"].present?
          fn = entry.name.split("/").last
          entry.extract(File.join(FILES_FOLDER, fn)) { true } # { true } is to overwrite
          break
        end
      end
    end
    true
  end

  def self.update
    self.update_maxmind # update via internet
    Dir[File.join(FILES_FOLDER, "states.*")].each do |state_fn|
      self.install(state_fn.split(".").last.upcase.to_sym) # reinstall country
    end
    @countries, @states, @cities = [{}, {}, {}] # invalidades cache
    File.delete COUNTRIES_FN # force countries.yml to be generated at next call of CS.countries
    true
  end

  # constants: CVS position
  ID = 0
  COUNTRY = 4
  COUNTRY_LONG = 5
  STATE = 6
  STATE_LONG = 7
  CITY = 10

  def self.install(country, geo_type=nil, geo_parent=nil)
    # get CSV if doesn't exists
    update_maxmind unless File.exists? MAXMIND_DB_FN

    # normalize "country"
    country = country.to_s.upcase

    # some state codes are empty: we'll use "states-replace" in these cases
    states_replace_fn = File.join(FILES_FOLDER, "states-replace.yml")
    states_replace = YAML::load_file(states_replace_fn).symbolize_keys
    states_replace = states_replace[country.to_sym] || {} # we need just this country
    states_replace_inv = states_replace.invert # invert key with value, to ease the search

    # read CSV line by line
    cities = {}
    states = {}
    File.foreach(MAXMIND_DB_FN) do |line|
      rec = line.split(",")
      next if rec[COUNTRY] != country
      next if (rec[STATE].blank? && rec[STATE_LONG].blank?) || rec[CITY].blank?

      # some state codes are empty: we'll use "states-replace" in these cases
      rec[STATE] = states_replace_inv[rec[STATE_LONG]] if rec[STATE].blank?
      rec[STATE] = rec[STATE_LONG] if rec[STATE].blank? # there's no correspondent in states-replace: we'll use the long name as code

      # some long names are empty: we'll use "states-replace" to get the code
      rec[STATE_LONG] = states_replace[rec[STATE]] if rec[STATE_LONG].blank?

      # normalize
      rec[STATE] = rec[STATE].to_sym
      rec[CITY].gsub!(/\"/, "") # sometimes names come with a "\" char
      rec[STATE_LONG].gsub!(/\"/, "") # sometimes names come with a "\" char

      # cities list: {TX: ["Texas City", "Another", "Another 2"]}
      cities.merge!({rec[STATE] => []}) if ! states.has_key?(rec[STATE])
      cities[rec[STATE]] << rec[CITY]

      # states list: {TX: "Texas", CA: "California"}
      if ! states.has_key?(rec[STATE])
        state = {rec[STATE] => rec[STATE_LONG]}
        states.merge!(state)
      end
    end

    # sort
    cities = Hash[cities.sort]
    states = Hash[states.sort]
    cities.each { |k, v| cities[k].sort! }

    # save to states.us and cities.us
    states_fn = File.join(FILES_FOLDER, "#{country.downcase}/states")
    cities_fn = File.join(FILES_FOLDER, "#{country.downcase}/cities")
    File.open(states_fn, "w") { |f| f.write states.to_yaml }
    File.open(cities_fn, "w") { |f| f.write cities.to_yaml }
    File.chmod(0666, states_fn, cities_fn) # force permissions to rw_rw_rw_ (issue #3)
    
    return states if geo_type == "states"
    return cities if geo_type == "cities"
    []
  end

  def self.villages(country, district=nil)
    geo_children(country, "villages", district)
  end

  def self.districts(country, city=nil)
    geo_children(country, "districts", city)
  end

  def self.cities(country, state=nil)
    geo_children(country, "cities", state)
  end

  def self.states(country)
    geo_children(country, "states", nil, { abbr: 1 })
  end

  # list of all countries of the world (countries.yml)
  def self.countries
    if ! File.exists? COUNTRIES_FN
      # countries.yml doesn't exists, extract from MAXMIND_DB
      update_maxmind unless File.exists? MAXMIND_DB_FN

      # reads CSV line by line
      File.foreach(MAXMIND_DB_FN) do |line|
        rec = line.split(",")
        next if rec[COUNTRY].blank? || rec[COUNTRY_LONG].blank? # jump empty records
        country = rec[COUNTRY].to_s.upcase.to_sym # normalize to something like :US, :BR
        if @countries[country].blank?
          long = rec[COUNTRY_LONG].gsub(/\"/, "") # sometimes names come with a "\" char
          @countries[country] = long
        end
      end

      # sort and save to "countries.yml"
      @countries = Hash[@countries.sort]
      File.open(COUNTRIES_FN, "w") { |f| f.write @countries.to_yaml }
      File.chmod(0666, COUNTRIES_FN) # force permissions to rw_rw_rw_ (issue #3)
    else
      # countries.yml exists, just read it
      @countries = YAML::load_file(COUNTRIES_FN).symbolize_keys
    end
    @countries
  end

  private
    def self.geo_children(country, geo_type, geo_parent=nil, fields={})
      geo_db_fn = File.join(FILES_FOLDER, "#{country.to_s.downcase}/#{geo_type}.csv")

      if File.exists? geo_db_fn
        return self.load_geo(geo_db_fn, fields, geo_parent)
      else
        return self.install(country, geo_type, geo_parent) 
      end
    end

    def self.load_geo(geo_db_fn, fields={}, parent=nil)
      # normalize "parent"
      parent = parent.to_s.upcase
      geos = []

      fields = self.default_fields.merge(fields)

      # read CSV line by line
      File.foreach(geo_db_fn) do |line|
        rec = line.split(",")
        next if parent.present? && rec[fields[:parent]] != parent

        area = {}
        fields.each do |key, val|
          area[key.to_s] = rec[val.to_i].gsub(/\"/, "")  # sometimes names come with a "\" char
        end

        geos << area
      end

      geos
    end

    def self.default_fields
      {
        code: 0,
        parent: 1,
        name: 2
      }
    end
end