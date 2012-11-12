Create an instance:
  * `imagemagick = ImageMagick.new`
  
Load a material:
  * `imagemagick.load(material, lossless=true)`
  * exports the material's image
  * optional: lossless = true/false (converts jpg into bmp)
  
Edit the material:
  * `imagemagick.edit(material, convert_command, queue){ do_after_import() }`
  * reimports the material's image
  * optional: queue = true/false (wait until `imagemagick.execute` is called, or convert immediately)
  
Create a new material either based on an existing one:
  * `imagemagick.create(material, convert_command, queue){|new_material| do_after_import() }`
  
Or creating a new material purely with the convert command, giving a material name:
  * `imagemagick.create(materialname, convert_command, queue){|new_material| do_after_import() }`
