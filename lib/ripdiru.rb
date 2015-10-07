#!/usr/bin/env ruby

require "ripdiru/version"
require 'net/https'
require 'rexml/document'
require 'uri'
require 'pathname'
require 'base64'
require 'open-uri'
require 'date'
require 'fileutils'

module Ripdiru
  class DownloadTask

    TMPDIR = ENV['TMPDIR'] || '/tmp'
    SCHEDULE_URL = "http://www2.nhk.or.jp/hensei/api/noa.cgi?c=3&wide=1&mode=json"

    attr_accessor :station, :cache, :buffer, :outdir, :bitrate

    def initialize(station = nil, duration = 1800, *args)
      unless station
        abort "Usage: ripdiru [station-id]"
      end
      @station = station
      @channel = channel
      @duration = duration
      @cache = CacheDir.new(TMPDIR)
      @buffer = ENV['RIPDIRU_BUFFER'] || 60
      @outdir = ENV['RIPDIRU_OUTDIR'] || "#{ENV['HOME']}/Music/Radiru"
      @bitrate = ENV['RIPDIRU_BITRATE'] || '48k'
    end

    def channel
      case station
        when "NHK1"
          @mms_ch="netr1"
          @playpath="NetRadio_R1_flash@63346"
          @rtmp_ch="r1"
        when "NHK2"
          @mms_ch="netr2"
          @playpath="NetRadio_R2_flash@63342"
          @rtmp_ch="r2"
        when "FM"
          @mms_ch="netfm"
          @playpath="NetRadio_FM_flash@63343"
          @rtmp_ch="fm"
        else
          puts "invalid channel"
      end
    end

    def val(element, path)
      element.get_text(path)
    end

    def parse_time(str)
      DateTime.strptime("#{str}+0900", "%Y-%m-%d %H:%M:%S%Z").to_time
    end

    def now_playing(station)
      now = Time.now

      f = open(SCHEDULE_URL)
      xml = REXML::Document.new(f)

      REXML::XPath.each(xml, "//item") do |item|
        if val(item, "ch") == @mms_ch && val(item, "index") == '0'
          from, to = parse_time(val(item, "starttime")), parse_time(val(item, "endtime"))
          start_time = now.to_i + buffer
          return Program.new(
            id: now.strftime("%Y%m%d%H%M%S") + "-#{station}",
            station: station,
            title: val(item, "title"),
            from: from,
            to: to,
            duration: to.to_i - from.to_i,
            info: val(item, "link"),
          )
        end
      end
    end

    def run
      program = now_playing(station)

      duration = program.recording_duration + buffer

      tempfile = "#{TMPDIR}/#{program.id}.mp3"
      puts "Streaming #{program.title} ~ #{program.to.strftime("%H:%M")} (#{duration}s)"
      puts "Ripping audio file to #{tempfile}"

      command = %W(
        rtmpdump --live --quiet
        -r rtmpe://netradio-#{@rtmp_ch}-flash.nhk.jp
        --playpath #{@playpath}
        --app live
        -W http://www3.nhk.or.jp/netradio/files/swf/rtmpe.swf
        --live --stop #{duration} -o - |
        ffmpeg -y -i - -vn
        -loglevel error
        -metadata author="NHK"
        -metadata artist="#{program.station}"
        -metadata title="#{program.title} #{program.effective_date.strftime}"
        -metadata album="#{program.title}"
        -metadata genre=Radio
        -metadata year="#{program.effective_date.year}"
        -acodec libmp3lame -ar 44100 -ab #{bitrate} -ac 2
        -id3v2_version 3
        -t #{duration}
        #{tempfile}
      )

      Signal.trap(:INT) { puts "Recording interupted by user"}
      system command.join(" ")

      FileUtils.mkpath(outdir)
      File.rename tempfile, "#{outdir}/#{program.id}.mp3"

    end

    def abort(msg)
      puts msg
      exit 1
    end
  end

  class Program
    attr_accessor :id, :station, :title, :from, :to, :duration, :info
    def initialize(args = {})
      args.each do |k, v|
        send "#{k}=", v
      end
    end

    def effective_date
      time = from.hour < 5 ? from - 24 * 60 * 60 : from
      Date.new(time.year, time.month, time.day)
    end

    def recording_duration
      (to - Time.now).to_i
    end
  end

  class CacheDir
    attr_accessor :dir
    def initialize(dir)
      @dir = dir
      @paths = {}
    end

    def [](name)
      @paths[name] ||= Pathname.new(File.join(@dir, name))
    end
  end
end
