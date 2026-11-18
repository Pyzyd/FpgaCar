# Optional: copy as /sdcard/main.py to start turn validation on power-up.
# First back up the working capture launcher.
with open("/sdcard/turn_verify/field_turn.py") as script:
    source = script.read()
exec(source, {"__name__": "__main__"})
