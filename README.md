# AutoDISM: The automatic DISM utility
AutoDISM, as the name might imply, is my attempt at automating DISM runs by checking over which build of Windows you are running, and calling the appropriate files and command lines to run DISM for you.
I started this because it became tiresome to type in the long, convoluted command for each computer I need to run DISM on, and when you have 10+ computers a day, it takes its toll on the soul.
Also, this tool takes advantage of the fact that DISM doesn't seem to need the /index command, as all my testings seems to indicate it is smart enough to work out what it needs. If this is a problem, let me know with an issue ticket and I can change up the script, but I need to be able to reproduce the issue so I can test if it works.

# How to set up: A quick setup guide
Start by creating a folder with the build number of Windows you are working on. It will be a 5 digit number. Then navigate into this folder. Create a second folder, name it either 32 or 64 depending on the wordsize of your installed Windows. Navigate into this folder. You will need to copy the *install.wim* or *install.esd* file from an all in one ISO into its corresponding folder.
If you are copying this tool on a flash drive is that is running FAT32, and if the install file is larger than 4 gigabytes, you will need to use SplitWim.bat to split the WIM file into a smaller set of files and copy those instead.
Note that the batch file is smart enough to call whichever flavor of install you have, and there can exist one of three flavors, a compressed ESD, an uncompressed WIM, or a split SWM file.
If your install file is some other format, you will need to convert it.
Finally, please make sure your install file is an all on one, as to contain the files needed for HOME, PRO, ENTERPRISE, EDUCATION, or whatever. It should work if you run this with an installer that only contains what edition you need, but it looses its flexibility if you make that a habit, as well as being untested.
Finally, the github repo system won't allow me to add the install files here because they are gigantic, so you will have to source the build and architecture for each version you need. I've just been downloading them on an as-needed basis.

# How to use: A quick user guide
In an effort to make this as simple as possible, you just double click AutoDISM and let it work. If you are missing an appropriate install file, it will let you know and ask you to add it into the DISM kit.
