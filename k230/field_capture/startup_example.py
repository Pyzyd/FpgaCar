# Copy this file to /sdcard/main.py to auto-start the field photo sampler.
# Back up the currently working /sdcard/main.py before replacing it.
with open("/sdcard/field_capture.py") as script:
    source = script.read()
exec(source, {"__name__": "__main__"})
