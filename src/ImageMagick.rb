=begin

Copyright 2011, Andreas Eisenbarth
All Rights Reserved

Permission to use, copy, modify, and distribute this software for
any purpose and without fee is hereby granted, provided that the above
copyright notice appear in all copies.

THIS SOFTWARE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.

Name:         ImageMagick.rb
Author:       Andreas Eisenbarth
Description:  Class to control ImageMagick
              required by TextureResizer
Usage:        Create an instance:
                imagemagick = ImageMagick.new
              load a material:
                imagemagick.load(material, lossless)
                * exports the material's image
                * optional: lossless = true/false (converts jpg into bmp)
              edit the material:
                imagemagick.edit(material, convert_command, queue){ do_after_import() }
                * reimports the material's image
                * optional: queue = true/false (wait until imagemagick.execute is called, or convert immediately)
              create a new material either based on an existing one:
                imagemagick.create(material, convert_command, queue){|new_material| do_after_import() }
               or creating it purely with the convert command, giving a material name
                imagemagick.create(materialname, convert_command, queue){|new_material| do_after_import() }
Requirements: ImageMagick
                Windows: download it from this plugin's site or from the official site
                  http://www.imagemagick.org/script/binary-releases.php#windows
                  Place it either in the Plugins folder or at the location of your choice.
                  The Plugin will then ask you once for the install location.
                Linux (Wine): Your distribution most likely comes with native ImageMagick preinstalled,
                  if not install it from the repositories
                  or install the Windows version of ImageMagick into Wine as described above.
                OS X: ImageMagick can be installed with HomeBrew or MacPorts
Version:      1.4.3
Date:         23.11.2012

=end
require 'sketchup.rb'



module AE



class TextureResizer



class ImageMagick
@@caches = {}
@@app_observer = false
# get temporary folder that is writable
temp = [ENV['TMPDIR'], ENV['TMP'], ENV['TEMP'], ENV['USERPROFILE'], '/tmp', '.'].inject(nil){ |t,dir| (!t && dir && File.directory?(dir) && File.writable?(dir))? dir : t }
@@temp = File.join( File.expand_path(temp), "skp_"+Module.nesting[1].name[/[^\:]+$/].downcase)
OSX = ( Object::RUBY_PLATFORM =~ /(darwin)/i ) unless defined?(Module.nesting[0]::OSX)
WINE = ( File.exists?("C:/Windows/system32/winepath.exe" || File.exists?("Z:/usr/bin/wine")) && !OSX) unless defined?(Module.nesting[0]::WINE)
WIN = ( !OSX && !WINE ) unless defined?(Module.nesting[0]::WIN)
# whether to use native unix ImageMagick or ImageMagick through Wine
@@unix_native = WINE && File.exists?("Z:/bin/bash") && File.exists?("Z:/usr/bin/convert")
# location of portable ImageMagick
@@im_win = File.expand_path(File.join(Sketchup.find_support_file("Plugins"),"ImageMagick/convert.exe"))
@@debug = false


# Check if ImageMagick is installed, otherwise offer to select an alternative install location.
# @return [Boolean] whether ImageMagick is installed on Windows/Wine system.
#
def self.installed?
  # Windows version of ImageMagick
  if WIN || WINE && !@@unix_native
    @@im_win = Sketchup.read_default("ImageMagick", "location", @@im_win) if !File.exists?(@@im_win)
    if !File.exists?(@@im_win)
      UI.messagebox("Make Unique Texture HQ requires ImageMagick, but it could not be found. \nPlease navigate to the ImageMagick folder and select the file 'convert.exe' or install ImageMagick from \nhttp://www.imagemagick.org/script/binary-releases.php.",MB_OK)
      path = UI.openpanel("Please select the file path of convert.exe", @@im_win, "convert.exe")
      Sketchup.write_default("ImageMagick", "location", path)
      return false if !File.exists?(path.to_s)
    end
  end
  return true
end # def imagemagick_installed?



# Get the texture resolution of a face. # TODO: improve this method. Make it faster and more logical.
# @param [Sketchup::Face] face
# @param [Boolean] front  side of the face (frontface=true, backface=false)
# @param [Geom::Point3d] c  point at which the resolution should be determined
# @return [Float] resolution, length of one model unit (inch) in texture units (pixels). px/inch
#
def self.texture_resolution(face, front=true, c=nil)
  return 1 unless face.is_a?(Sketchup::Face)
  @@tw ||= Sketchup.create_texture_writer
  # Get points of a square (with side length 0.01) in object space.
  c = face.bounds.center if c.nil?
  vec0 = face.normal.axes.x
  vec0.length = 0.005
  vec1 = face.normal.axes.y
  vec1.length = 0.005
  ps = [c+vec0+vec1, c+vec0-vec1, c-vec0-vec1, c-vec0+vec1]
  # Get the corresponding UVs.
  uv_help = face.get_UVHelper(true, true, @@tw)
  uvs = ps.collect{|p| (front)? uv_help.get_front_UVQ(p) : uv_help.get_back_UVQ(p) }
  uvs.each{|uv| uv.x/=uv.z.to_f; uv.y/=uv.z.to_f}
  # Area of a (possible) quadrilateral.
  uv_area = 0.5*( (uvs[0].y-uvs[2].y)*(uvs[3].x-uvs[1].x) + (uvs[1].y-uvs[3].y)*(uvs[0].x-uvs[2].x) ).abs
  # Average side length of the quadrilateral in UV units.
  r = Math.sqrt(uv_area)
  m = (front)? face.material : face.back_material
  w = m.texture.image_width
  h = m.texture.image_height
  # One model unit (inch) in texture units (pixels)
  return 100 * r * Math.sqrt(w*h)
end # def texture_resolution



# Convert a random string into a proper, unique filename.
# @param [String] dir  directory where the file should go
# @param [String] string  any user input
# @param [String] ext  optionally force a specific extension if the string doesn't contain one
# @return [String] a complete file path
#
def self.to_filename(dir, string, ext=nil)
  # separate extension from basename
  ext = File.extname(string) if ext.nil?
  string = File.basename(string, ext.to_s)
  # clean up basename
  string = string[/.{1,30}/].gsub(/\n|\r/,"").gsub(/[^0-9a-zA-Z\-\_\.\(\)\#]+/,"_").gsub(/^_+|_+$/,"").to_s
  string = "file" if string.empty?
  base = File.join(dir, string)
  # detect collision of filenames and return alternative filename (numbered)
  base_orig = base
  i = 0
  while File.exists?(base + ext)
    base = base_orig + i.to_s
    i += 1
  end
  return base + ext
end # def to_filename

def to_filename(dir, string, ext=nil)
  return self.class.to_filename(dir, string, ext)
end



# Initialize, create a temporary cache folder that is unique for each model.
#
def initialize
  @model = Sketchup.active_model
  @tw = Sketchup.create_texture_writer
  @cache_dir = @@temp + Time.now.to_i.to_s[/.{5}$/]
  @cache = {}
  @cmds = []
  @cmd_blocks = []
  Dir.mkdir(@cache_dir) if !File.exists?(@cache_dir)
  @@caches[@model] = self
  @active = true
  @model.add_observer(ModelObserver.new)
  @@app_observer = Sketchup.add_observer(QuitObserver.new) if !@@app_observer
end # def



# Return hash of all current models/caches.
# @return [Hash] a hash assignment of model => cache directory
def self.caches
  return @@caches
end



# Check if a material has been loaded into this cache.
# @param [Sketchup::Material] material
# @return [Boolean] Whether the material has been loaded into the cache.
def loaded?(material)
  return (@cache[material] && File.exists?(@cache[material][:path]))? true : false
end



# Get the exported texture path in the system's format.
# @param [Sketchup::Material] material
# @return [String] file path (for use in terminal)
#
def get_path(material)
  path = @cache[material][:path]
  if WINE && @@unix_native == true
    return %["`wine winepath.exe -u '#{path}'`"]
  elsif WIN || WINE
    return %["#{path.gsub(/\//,'//').gsub(/\//,'\\')}"]
  elsif OSX
    return path
  end
end



# Load a material into the cache, export its image file.
# @param [Sketchup::Material] material
# @param[Boolean] lossless  whether to export a copy of jpeg/jpg images in bmp format
# @return [String] the file path in the system's format (not ruby format)
#
def load(material, lossless=true)
  return (puts(material.name+": is untextured"); nil) if material.materialType < 1 # refuse untextured materials
  return get_path(material) if loaded?(material)
  Dir.mkdir(@cache_dir) if !File.exists?(@cache_dir)
  filename = File.basename(material.texture.filename)
  ext = (!File.extname(filename))? ".png" : nil # force extension if filename has no extension
  path = to_filename(@cache_dir, filename, ext)
  # create temporary group to export texture image without uv-mapping
  tmp_group = @model.entities.add_group
  tmp_group.material = material
  @tw.load(tmp_group) rescue (puts(material.name+": could not load material into TextureWriter"); return nil)
  success = @tw.write(tmp_group, path, true)
  return (puts(material.name+": could not write file "+path); nil) if success!=0
  @cache[material] = {:path => path}
  # export a lossless copy for lossy formats (to preserve quality and for speed)
  if lossless && (filename[/\.jpg$/] || filename[/\.jpeg$/i])
    orig = path
    path = to_filename(@cache_dir, filename.sub(/\..{1,4}$/, ".bmp") )
    success = @tw.write(tmp_group, path, true)
    if success==0
      @cache[material][:path] = path
      @cache[material][:orig] = orig
    else
      puts(material.name+": could not write file "+path)
    end
  end
  @model.entities.erase_entities(tmp_group)
  return (success==0)? get_path(material) : nil
end



# Edit a material and reimport it.
# Special convert command where input file is output file.
# @param [Sketchup::Material] material
# @param [String] convert_option  ImageMagick convert command (between input and output)
# @param [Boolean] queue  whether to wait until "execute" is explicitely called or execute the command immediately
# @param [Proc] block  code block to execute after this material has been edited and reimported
#
def edit(material, convert_option, queue=false, &block)
  load(material) if !loaded?(material)
  path = @cache[material][:path]
  convert(path, convert_option, path, queue){
    reimport(material)
    block.call if block_given?
  }
end



# Create a new material and import it
# Special convert command where input file is output file.
# @param [Sketchup::Material, String] material  either a Sketchup::Material to clone or a string of the new material's name
# @param [String] convert_option  ImageMagick convert command (between input and output)
# @param [Boolean] queue  whether to wait until "execute" is explicitely called or execute the command immediately
# @param [Proc] block  code block to execute after this material has been edited and reimported
# @return [Sketchup::Material] the new material
#
def create(material, convert_option, queue=false, &block)
  if material.class == Sketchup::Material
    load(material) if !loaded?(material)
    path = @cache[material][:path]
    new_material = clone(material)
    new_name = new_material.display_name
  elsif material.class == String || material.class == nil
    new_name = material.to_s
    (i = 0; i += 1 while @model.materials[new_name+i.to_s]; new_name = new_name+i.to_s) if @model.materials[new_name]
    new_material = @model.materials.add(new_name)
    path = ""
  end
  new_path = to_filename(@cache_dir, new_name)
  @cache[new_material] = {:path => path}
  # convert
  convert(path, convert_option, new_path, queue){
    reimport(new_material, new_path)
    block.call(new_material) if block_given?
  }
  return new_material
end



# Convert a material.
# This is the raw convert command.
# @param [String] input  file path of input image
# @param [String] convert_option  ImageMagick convert command (between input and output)
# @param [String] output  file path of the newly created output image
# @param [Boolean] queue  whether to wait until "execute" is explicitely called or execute the command immediately
# @param [Proc] block  code block to execute after this image has been converted
#
def convert(input, convert_option, output=input, queue=false, &block)
  if WINE && @@unix_native == true
    executable = 'convert'
    input = %["`wine winepath.exe -u '#{input}'`"] if !input.to_s.nil?
    output = %["`wine winepath.exe -u '#{output}'`"] if !input.to_s.nil?
  elsif WIN || WINE
    executable = %["#{@@im_win.gsub(/\//,'//').gsub(/\//,'\\')}"]
    input = %["#{input.gsub(/\//,'//').gsub(/\//,'\\')}"] if !input.to_s.nil?
    output = %["#{output.gsub(/\//,'//').gsub(/\//,'\\')}"] if !input.to_s.nil?
  elsif OSX
    executable = 'convert'
    input = %["#{input}"] if !input.to_s.nil?
    output = %["#{output}"] if !input.to_s.nil?
  end
  cmd = executable + ' ' + input.to_s + ' ' + convert_option + ' ' + output.to_s
  if queue
    @cmd_blocks << block if block_given?
    @cmds << cmd
    return
  else
  # execute single shell command (if it is not queued up)
    run_shell_command(cmd, &block)
  end
end



# Batch-process all materials that have been queued.
# @param [Proc] block  code block to execute after all images have been converted
#
def execute(&block)
  @active = true # An action is running now.
  cmd_blocks = @cmd_blocks # save array temporarily for block because instance variable will be cleared immediately
  bigblock = Proc.new{
    cmd_blocks.each{|p| p.call}
    block.call if block_given?
#    @cmds = [] # TODO better use this? Problem: what if new command is added while this is not finished?
#    @cmd_block = []
  }
  # batch execute shell commands
  run_shell_command(@cmds, &bigblock)
  @cmds = []
  @cmd_blocks = []
end



# Reimport a material.
# @param [Sketchup::Material] material
# @param [String] path  optional file path from where to import the image.
#   If not given, original material's file path will be used.
#
def reimport(material, path=nil)
  path = @cache[material][:path] if path.nil? && loaded?(material)
  return (puts("file "+path+" not found")) if !File.exists?(path)
  rw = material.texture.width # real-world width
  rh = material.texture.height # real-world height
  a = material.alpha
  c = material.color
  # re-import texture
  material.texture = path
  # fix texture size (SketchUp changes it sometimes after replacing the image file!)
  material.texture.size = [rw,rh]
  material.alpha = a
  #material.color = c FIXME: API bug, this sets always "colorized"
end # def reimport



# Reimport all textures in original file format.
# If original file was a lossy format, convert temporary lossless bmp back into the lossy format.
#
def apply
  @cache.each{|material, hash|
    if hash[:orig]
      convert(hash[:path], "", hash[:orig]){
        reimport(material, hash{:orig})
      }
    end
  }
end



# Purge all cached files in this cache.
#
def purge
  Dir.foreach(@cache_dir){|f|
    next if f=='.' or f=='..'
    File.delete(File.join(@cache_dir, f)) unless @@debug
  } if File.exists?(@cache_dir) && Dir.entries(@cache_dir)[2]
  @cache = {}
end



# Erase this cache completely (delete containing folder).
#
def erase
  purge
  Dir.delete(@cache_dir) if File.exists?(@cache_dir) unless @@debug
  @@caches.delete(self)
end



# Cancel all running actions.
#
def cancel
  @active = false
  purge
end



private



class ModelObserver < Sketchup::ModelObserver
  # Purge cached images when they are invalid because of Undo command.
  # When the user undoes, the image(s) in the cache can't be undone,
  # so we will purge them and export them again.
  #
  def onTransactionUndo(model)
    ImageMagick.caches[model].purge if !ImageMagick.caches[model].nil? # Module.nesting[1]
  end
  # Apply images in original file format if lossy formats have been replace by lossless formats
  #
  def onPreSaveModel(model)
    ImageMagick.caches[model].apply if !ImageMagick.caches[model].nil? # Module.nesting[1]
  end
end



class QuitObserver < Sketchup::AppObserver
  # Erase all chaches when the application is closed.
  #
  def onQuit()
    ImageMagick.caches.each{|model, cache| # Module.nesting[1]
      cache.erase if !cache.nil?
    }
  end
end



# Clone a material
# @param [Sketchup::Material] material a Sketchup::Material to clone
# @param [String] new_name (optional) name for the new material
# @returns [Sketchup::Material] the newly created material object
#
def clone(material, new_name=material.display_name)
  (i = 0; i += 1 while @model.materials[new_name+i.to_s]; new_name = new_name+i.to_s) if @model.materials[new_name]
  new_material = @model.materials.add(new_name)
  new_material.alpha = material.alpha
  #new_material.color = material.color FIXME: API bug, this sets always "colorized"
  if material.materialType > 0
    load(material) if !loaded?(material)
    path = @cache[material][:path]
    @cache[new_material] = {:path => path}
    new_material.texture = path
    # fix texture size (SketchUp changes it sometimes after replacing the image file!)
    new_material.texture.size = [material.texture.width, material.texture.height]
  end
  return new_material
end



# Execute a single command / a list of commands.
# @param [String] cmd command string or array containing command strings
# @param [Proc] block code block to execute after the commands have finished
#
def run_shell_command(cmd, &block)
  cmd = [cmd] if cmd.class != Array
  puts cmd.inspect if @@debug
  # other
  if WINE
    # check for native unix ImageMagick installation
    if @@unix_native == true
      fsh = File.join(@cache_dir, "temporary.sh")
      File.open(fsh, "w"){|f|
        f.puts %[ #!/bin/sh]
        cmd.each{|c| f.print(c+";") }
        f.puts %[touch "`wine winepath.exe -u '#{@cache_dir}'`/finished.txt";]
      }
      begin
        system(%[Z:\\bin\\bash -c "bash `wine winepath.exe -u "#{fsh}"`"])
      rescue
      end
    # otherwise use Windows ImageMagick as distributed with this plugin
    #   no WScript necessary because Wine does not show black console window
    else
      # create a batch script with the commands
      fbat = File.join(@cache_dir, "temporary.bat")
      File.open(fbat, "w"){|f|
        f.puts "@echo off"
        cmd.each{|c| f.puts(c) }
        f.puts %[echo "finished" > "#{@cache_dir.gsub(/\//,'//').gsub(/\//,'\\')}\\finished.txt"]
      }
      system(%[#{fbat}])
    end
  # Windows
  elsif WIN
    # create a batch script with the commands
    fbat = File.join(@cache_dir, "temporary.bat")
    File.open(fbat, "w"){|f|
      f.puts "@echo off"
      cmd.each{|c| f.puts(c) }
      f.puts %[echo "finished" > "#{@cache_dir.gsub(/\//,'//').gsub(/\//,'\\')}\\finished.txt"]
    }
    # create a Visual Basic file to launch the batch script without black console window
    fvbs = File.join(@cache_dir, "temporary.vbs")
    File.open(fvbs, "w"){|f|
      f.puts %[Set WshShell = CreateObject("WScript.Shell")]
      f.puts %[WshShell.Run """#{fbat}""", 0]
      # a third argument bWaitOnReturn=true would wait for the script to finish (synchronously),
      # but uses SketchUp's process and is 20 times slower.
      # f.puts %[WshShell.Run """#{fbat}""", 0, true]
      f.puts %[WScript.Quit]
    }
    system(%[wscript #{fvbs}])
  # OS X
  elsif OSX
    fsh = File.join(@cache_dir, "temporary.sh")
    File.open(fsh, "w"){|f|
      f.puts %[ #!/bin/sh]
      cmd.each{|c| f.print(c+";") }
      f.puts %[touch "#{@cache_dir}/finished.txt";]
    }
    system(%[bash #{fsh}])
  end
  # since the batch script runs asynchronously, we need to know when it is finished
  # the batch script creates a "finished.txt" file, and we continue only when it is created
  file_observer(File.join(@cache_dir, "finished.txt"), &block)
end # def run_shell_command



# Observe when a file is created.
# @param [String] file file path
# @param [Proc] block code block to execute when file is created
#
def file_observer(file, &block)
  if !File.exists?(file) && @active
    UI.start_timer(0.2){ file_observer(file, &block) }
  else
    File.delete(file) rescue nil unless @@debug
    block.call
  end
end # def file_observer



end # class ImageMagick



end # class TextureResizer



end # module AE



file_loaded(__FILE__)
