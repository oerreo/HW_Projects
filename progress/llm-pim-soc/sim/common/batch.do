# Batch run macro for vsim -c. Command errors and breaks ($stop, $fatal, Ctrl-C)
# exit with code 1 instead of waiting at the prompt. $finish exits vsim directly
# (run.sh passes -onfinish exit).
onerror {quit -f -code 1}
onbreak {quit -f -code 1}
run -all
quit -f
