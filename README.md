This is a library to simplify editing of textures using external programs (like ImageMagick). It abstracts filename collisions, exporting and asynchronous re-importing of image files. It can be easily adopted to any other command line image editing program.

Create an instance:
  * `imagemagick = ImageMagick.new`
  
Load a material:
  * `imagemagick.load(material, lossless=true)`
  * exports the material's image
  * optional: lossless = true/false (converts jpg into bmp)
  
Edit the material:
  * `imagemagick.edit(material, convert_command, queue=false){ do_after_import() }`
  * reimports the material's image
  * optional: queue = true/false queues the image for batch conversion instead of editing it immediately
    call `imagemagick.execute` to start the batch conversion
  
Create a new material either based on an existing one:
  * `imagemagick.create(material, convert_command, queue=false){|new_material| do_after_import() }`
  
Or creating a new material purely with the convert command, giving a material name:
  * `imagemagick.create(materialname, convert_command, queue){|new_material| do_after_import() }`
