# Optional /sdcard/main.py launcher after the two boards pass the bench check.
with open("/sdcard/turn_verify/turn_with_ti60.py") as script:
    source = script.read()
exec(source, {"__name__": "__main__"})
