=begin

Copyright 2011-2013, Andreas Eisenbarth
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
                Windows:
                  Download it from this plugin's site or from the official site
                  http://www.imagemagick.org/script/binary-releases.php#windows
                  Place it either in the Plugins folder or at the location of your choice.
                  The Plugin will then ask you once for the install location.
                Linux (Wine):
                  You can use either native ImageMagick (much faster)
                  (your distribution probably comes with "imagemagick" preinstalled,
                  if not install it from the repositories. The script also assumes
                  Wine has the "/" directory linked to a Windows "Z:" drive.)
                  or install the Windows version of ImageMagick into Wine exactly
                  as described above for Windows.
                OS X: ImageMagick can be installed with HomeBrew or MacPorts
Version:      1.4.
Date:         16.04.2013

=end
require 'sketchup.rb'



class ImageMagick
@@caches = {}
@@app_observer = false
# Platform detection.
OSX = ( Object::RUBY_PLATFORM =~ /(darwin)/i ) unless defined?(self::OSX)
WINE = ( File.exists?("C:/Windows/system32/winepath.exe" || File.exists?("Z:/usr/bin/wine")) && !OSX) unless defined?(self::WINE)
WIN = ( !OSX && !WINE ) unless defined?(self::WIN)
# Whether to use native unix ImageMagick or ImageMagick through Wine.
@@unix_native = WINE && File.exists?("Z:/bin/sh") && File.exists?("Z:/usr/bin/convert")
# Location of ImageMagick on Windows.
@@im_win = $LOAD_PATH.find{|p| f = File.join(p, "ImageMagick", "convert.exe"); break f if File.exists?(f)}
# Get a temporary folder that is writable.
temp = [ENV['TMPDIR'], ENV['TMP'], ENV['TEMP'], ENV['USERPROFILE'], '/tmp', '.'].inject(nil){ |t,dir| (!t && dir && File.directory?(dir) && File.writable?(dir))? dir : t }
temp = "Z:/tmp" if WINE && @@unix_native
@@temp = File.join( File.expand_path(temp), "skp_"+Module.nesting[1].name[/[^\:]+$/].downcase)
@@debug = false unless defined?(@@debug)
@@async = true unless defined?(@@async)


# Check if ImageMagick is installed on a Windows-based system, otherwise offer to select an alternative install location.
# @return [Boolean] whether ImageMagick is installed on Windows/Wine system.
#
def self.installed?
  # Windows version of ImageMagick
  if WIN || WINE && !@@unix_native
    @@im_win = Sketchup.read_default("ImageMagick", "location", @@im_win) if !File.exists?(@@im_win)
    if !File.exists?(@@im_win)
      UI.messagebox("This Plugin requires ImageMagick, but it could not be found. \nPlease navigate to the ImageMagick folder and select the file 'convert.exe' or install ImageMagick from \nhttp://www.imagemagick.org/script/binary-releases.php.",MB_OK)
      path = UI.openpanel("Please select the file path of convert.exe", @@im_win, "convert.exe")
      return false if !File.exists?(path.to_s)
      Sketchup.write_default("ImageMagick", "location", path)
    end
  end
  return true
end # def imagemagick_installed?



# Get the texture resolution of a face.
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
  # Separate extension from basename.
  ext = File.extname(string) if ext.nil?
  string = File.basename(string, ext.to_s)
  # Clean up basename.
  string = string[/.{1,30}/].gsub(/\n|\r/,"").gsub(/[^0-9a-zA-Z\-\_\.\(\)\#]+/,"_").gsub(/^_+|_+$/,"").to_s
  string = "file" if string.empty?
  base = File.join(dir, string)
  # Detect collision of filenames and return alternative filename (numbered).
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
  @cache_dir = get_cache_dir
  Dir.mkdir(@cache_dir) unless File.exists?(@cache_dir)
  @cache = {}
  @cmds = []
  @cmd_blocks = []
  # Have one instance of ImageMagick for each model in a multi-document interface.
  @@caches[@model] = self
  @active = true  # TODO: Rename this into something like @simulate or @noob ?
  @model.add_observer(ModelObserver.new)
  @@app_observer = Sketchup.add_observer(QuitObserver.new) if !@@app_observer
end # def



# Toogle between asynchronous and synchronous behavior.
# Asynchronous: After executing the command, Ruby continues with the next line of
# code and SketchUp stays responsive for tool actions.
# Synchronous: no action or camera movement possible until image editing is finished (This is mostly useful for testing purposes).
#
def self.async
  @@async
end
def self.async=(boolean)
  @@async = boolean
end
def self.async!
  @@async = true
end
def self.sync
  !@@async
end
def self.sync=(boolean)
  @@async = !boolean
  return boolean
end
def self.sync!
  @@async = false
  return true
end
class << self
  alias_method(:asynchronous, :async)
  alias_method(:asynchronous=, :async=)
  alias_method(:asynchronous!, :async!)
  alias_method(:synchronous, :sync)
  alias_method(:synchronous=, :sync=)
  alias_method(:synchronous!, :sync!)
end


# Generate a unique file path for a new cache directory.
def get_cache_dir
  @@temp + Time.now.to_i.to_s[/.{5}$/]
end # def get_cache_dir
private :get_cache_dir



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
  if WINE && @@unix_native # TODO: This function is probably not used.
    # Not sure if this should return the Wine=Windows format or Unix format.
    return path[/^Z\:/] ? %["#{path.sub(/Z\:/,"")}"] : %["`wine winepath.exe -u '#{path}'`"]
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
def load(material, lossless=false)
  return (puts(material.name+": is untextured"); nil) if material.materialType < 1 # refuse untextured materials
  return get_path(material) if loaded?(material)
  filename = File.basename(material.texture.filename)
  # Force extension if filename has no extension.
  ext = (File.extname(filename).empty?)? ".png" : nil
  path = to_filename(@cache_dir, filename, ext)
  Dir.mkdir(@cache_dir) if !File.exists?(@cache_dir)
  # Create temporary group to export texture image without UV-mapping.
  tmp_group = @model.entities.add_group
  tmp_group.material = material
  @tw.load(tmp_group) rescue (puts(material.name+": could not load material into TextureWriter"); return nil)
  success = @tw.write(tmp_group, path, true)
  return (puts(material.name+": could not write file "+path); nil) if success!=0
  @cache[material] = {:path => path}
  # Export a lossless copy for lossy formats (to preserve quality and for speed).
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
  convert(path, convert_option, path, queue){|result|
    reimport(material)
    block.call(result) if block_given?
  }
end



# Create a new material and import it.
# Special convert command where input file is output file.
# @param [Sketchup::Material, String] material  either a Sketchup::Material to clone or a string of the new material's name
# @param [String] convert_option  ImageMagick convert command (between input and output)
# @param [Boolean] queue  whether to wait until "execute" is explicitely called or execute the command immediately
# @param [Proc] block  code block to execute after this material has been edited and reimported
# @return [Sketchup::Material] the new material
#
def create(material, convert_option, queue=false, &block)
  # Clone the given material and export its texture for conversion.
  if material.class == Sketchup::Material
    load(material) if !loaded?(material)
    path = @cache[material][:path]
    new_material = clone(material)
    new_name = new_material.display_name
  # Or create an empty material and let ImageMagick generate a texture image.
  elsif material.class == String || material.class == nil
    new_name = material.to_s
    (i = 0; i += 1 while @model.materials[new_name+i.to_s]; new_name = new_name+i.to_s) if @model.materials[new_name]
    new_material = @model.materials.add(new_name)
    path = "" # In this case, the convert command needs to create a new image.
  end
  new_path = to_filename(@cache_dir, new_name)
  @cache[new_material] = {:path => new_path}
  # Convert.
  convert(path, convert_option, new_path, queue){|result|
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
  if WINE && @@unix_native
    executable = 'convert'
    input = input[/^Z\:/] ? %["#{input.sub(/Z\:/,"")}"] : %["`wine winepath.exe -u '#{input}'`"]
    output = output[/^Z\:/] ? %["#{output.sub(/Z\:/,"")}"] : %["`wine winepath.exe -u '#{output}'`"]
  elsif WIN || WINE
    executable = %["#{@@im_win.gsub(/\//,'//').gsub(/\//,'\\')}"]
    input = %["#{input.gsub(/\//,'//').gsub(/\//,'\\')}"]
    output = %["#{output.gsub(/\//,'//').gsub(/\//,'\\')}"]
  elsif OSX
    executable = 'convert'
    input = %["#{input}"]
    output = %["#{output}"]
  end
  # Compose the command.
  cmd = executable + ' ' + input.to_s + ' ' + convert_option + ' ' + output.to_s
  if queue
    # Execute it later.
    @cmd_blocks << block if block_given?
    @cmds << cmd
    return
  else
    # Execute single shell command now (if it is not queued up).
    run_shell_command(cmd, &block)
  end
end



# Batch-process all materials that have been queued.
# @param [Proc] block  code block to execute after all images have been converted
#
def execute(&block)
  # An action is running now.
  @active = true
  # Save array temporarily for block because instance variable will be cleared immediately.
  cmd_blocks = @cmd_blocks
  bigblock = Proc.new{|result|
    cmd_blocks.each{|p| p.call(result)}
    block.call(result) if block_given?
  }
  # Batch execute shell commands.
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
  return (puts("file "+path+" not found")) if path.nil? || !File.exists?(path)
  rw = material.texture.width # real-world width
  rh = material.texture.height # real-world height
  a = material.alpha
  c = material.color
  # Re-import texture.
  material.texture = path
  # Fix the texture size. (SketchUp changes it sometimes after replacing the image file!)
  material.texture.size = [rw,rh]
  material.alpha = a
  # material.color = c # FIXME: API bug, this sets always "colorized".
end # def reimport



# Reimport all textures in original file format.
# If original file was a lossy format, convert temporary lossless bmp back into the lossy format.
#
def apply
  @cache.each{|material, hash|
    if hash[:orig]
      convert(hash[:path], "", hash[:orig]){|result|
        reimport(material, hash{:orig})
      }
    end
  }
end



# Purge all cached files in this cache.
#
def purge
  Dir.foreach(@cache_dir){|f|
    file = File.join(@cache_dir, f)
    next unless File.file?(file)
    File.delete(file) rescue nil unless @@debug
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
    ImageMagick.caches[model].purge if !ImageMagick.caches[model].nil?
  end
  # Apply images in original file format if lossy formats have been replace by lossless formats.
  #
  def onPreSaveModel(model)
    ImageMagick.caches[model].apply if !ImageMagick.caches[model].nil?
  end
end



class QuitObserver < Sketchup::AppObserver
  # Erase all chaches when the application is closed.
  #
  def onQuit()
    ImageMagick.caches.each{|model, cache|
      cache.erase if !cache.nil?
    }
  end
end



# Clone a material.
# @param [Sketchup::Material] material a Sketchup::Material to clone
# @param [String] new_name (optional) name for the new material
# @returns [Sketchup::Material] the newly created material object
#
def clone(material, new_name=material.display_name)
  (i = 0; i += 1 while @model.materials[new_name+i.to_s]; new_name = new_name+i.to_s) if @model.materials[new_name]
  new_material = @model.materials.add(new_name)
  new_material.alpha = material.alpha
  # new_material.color = material.color # FIXME: API bug, this sets always "colorized".
  if material.materialType > 0
    load(material) if !loaded?(material)
    path = @cache[material][:path]
    @cache[new_material] = {:path => path}
    new_material.texture = path
    # Fix the texture size. (SketchUp changes it sometimes after replacing the image file!)
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
  # Other
  if WINE
    # Check for native unix ImageMagick installation.
    if @@unix_native
      fsh = File.join(@cache_dir, "commands.sh")
      File.open(fsh, "w"){|f|
        f.puts %[ #!/bin/sh]
        f.puts %[dir="#{@cache_dir.sub(/^Z\:/,"")}";]
        cmd.each{|c| f.puts(c + %[ >> "$dir/tmp.txt";]) }
        f.puts %[mv $dir/tmp.txt "$dir/result.txt";]
        f.puts %[exit 0]
      }
      return unless @active
      # Make the script executable.
      system(%[Z:\\bin\\chmod a+x "#{fsh.sub(/Z\:/,"")}"]) rescue nil
      # Run it.
      system(%[Z:\\bin\\sh "#{fsh.sub(/Z\:/,"")}"]) rescue nil
    # Otherwise use Windows version of ImageMagick as distributed with this plugin.
    #   no WScript necessary because Wine does not show black console window
    else
      # Create a batch script with the commands.
      fbat = File.join(@cache_dir, "commands.bat")
      File.open(fbat, "w"){|f|
        f.puts "@echo off"
        cmd.each{|c| f.puts(c) }
        f.puts %[echo "finished" > "#{@cache_dir.gsub(/\//,'//').gsub(/\//,'\\')}\\result.txt"]
      }
      return unless @active
      system(%[#{fbat}])
    end
  # Windows
  elsif WIN
    # Create a batch script with the commands.
    fbat = File.join(@cache_dir, "commands.bat")
    File.open(fbat, "w"){|f|
      f.puts "@echo off"
      cmd.each{|c| f.puts(c) }
      f.puts %[echo "finished" > "#{@cache_dir.gsub(/\//,'//').gsub(/\//,'\\')}\\result.txt"]
    }
    # Create a Visual Basic file to launch the batch script without black console window.
    fvbs = File.join(@cache_dir, "commands.vbs")
    File.open(fvbs, "w"){|f|
      f.puts %[Set WshShell = CreateObject("WScript.Shell")]
      f.puts %[WshShell.Run """#{fbat}""", 0]
      # A third argument bWaitOnReturn=true would wait for the script to finish (synchronously),
      # but uses SketchUp's process and is 20 times slower.
      # f.puts %[WshShell.Run """#{fbat}""", 0, true]
      f.puts %[WScript.Quit]
    }
    return unless @active
    system(%[wscript #{fvbs}])
  # OS X
  elsif OSX
    fsh = File.join(@cache_dir, "commands.sh")
    File.open(fsh, "w"){|f|
      f.puts %[ #!/bin/sh]
      cmd.each{|c| f.print(c+";") }
      f.puts %[touch "#{@cache_dir}/result.txt";]
    }
    return unless @active
    system(%[sh #{fsh}])
  end
  time_started = Time.now
  # Since the batch script runs asynchronously, we need to know when it is finished.
  # The batch script creates a "result.txt" file, and we continue only when it is created.
  file_observer(File.join(@cache_dir, "result.txt")){
    puts("#{(Time.now-time_started).to_f}s") if @@debug
    File.open(File.join(@cache_dir, "result.txt")){|file|
      result = file.read
      block.call(result)
    }
  }
end # def run_shell_command



# Observe when a file is created.
# @param [String] file file path
# @param [Proc] block code block to execute when file is created
#
def file_observer(file, &block)
  puts("File.exists?('#{file}') # #{File.exists?(file)}") if @@debug
  if !File.exists?(file) && @active
    if @@async
      t = UI.start_timer(0.2){#, false){
        #UI.stop_timer(t) rescue nil # Make sure that the timer does not run away.
        file_observer(file, &block)
      }
    else
      # This change makes everything synchronous.
      sleep(0.2)
      file_observer(file, &block)
    end
    false
  else
    block.call if block_given?
    File.delete(file) rescue nil unless @@debug
    true
  end
end # def file_observer



end # class ImageMagick



file_loaded(__FILE__)
