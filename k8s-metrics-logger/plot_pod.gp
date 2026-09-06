# plot_pod.gp
# Usage:
#  gnuplot -e "input_file='k8s_metrics.csv'; namespace='kube-cert-manager'; pod='cert-manager-6546d94fd7-4v8pr'; output_file='pod.png'; cpu_min=0; cpu_max=400; mem_min=0; mem_max=1024" plot_pod.gp
#
# cpu_min/cpu_max are in millicores (m). Example: 400m -> cpu_max=400
# mem_min/mem_max are in Mi (mebibytes). Example: 1024Mi -> mem_max=1024

# Only set defaults if variables were NOT provided via -e
if (!exists("input_file"))    input_file = "k8s_metrics.csv"
if (!exists("namespace"))     namespace = "kube-cert-manager"
if (!exists("pod"))           pod = "cert-manager-6546d94fd7-4v8pr"
if (!exists("output_file"))   output_file = sprintf("%s_%s.png", namespace, pod)
if (!exists("tmpfile"))       tmpfile = "/tmp/__pod_plot.csv"

# Debug: show the values gnuplot is using (visible in gnuplot stderr/stdout)
print "plot_pod.gp: input_file=" . input_file
print "plot_pod.gp: namespace=" . namespace
print "plot_pod.gp: pod=" . pod
print "plot_pod.gp: output_file=" . output_file
if (exists("cpu_min") && exists("cpu_max")) print sprintf("plot_pod.gp: cpu_min=%g cpu_max=%g", cpu_min, cpu_max)
if (exists("mem_min") && exists("mem_max")) print sprintf("plot_pod.gp: mem_min=%g mem_max=%g", mem_min, mem_max)

set terminal pngcairo size 1200,600 enhanced font "Sans,10"
set output output_file

set datafile separator ","

# Time handling (we'll enable timedata for plotting after computing stats)
set format x "%m/%d\n%H:%M"
set grid
set title sprintf("%s/%s — CPU (m) and Memory (MiB)", namespace, pod)

set ylabel "CPU (millicores)"
set ytics nomirror

set y2label "Memory (MiB)"
set y2tics

set key left top

# Build awk command to extract timestamp,cpu_m,mem_Mi for the chosen namespace/pod
awk_cmd = sprintf("awk -F, 'NR>1 && $2==\"%s\" && $3==\"%s\" { print $1 \",\" $4 \",\" $5 }' %s > %s", \
                  namespace, pod, input_file, tmpfile)
print "Running: " . awk_cmd
system(awk_cmd)

# Compute statistics on numeric columns: CPU (col 2) and MEM (col 3)
# stats cannot be used in timedata mode, so ensure xdata is unset.
unset xdata
# CPU stats (prefix CPU_)
stats tmpfile using 2 prefix "CPU" nooutput
# MEM stats (prefix MEM_)
stats tmpfile using 3 prefix "MEM" nooutput

if (CPU_records <= 0) {
    print sprintf("No data found for %s/%s in %s (filtered file %s is empty).", namespace, pod, input_file, tmpfile)
    print "Run the following to list available namespace/pod combos:"
    print "  awk -F, 'NR>1{print $2\",\"$3}' " . input_file . " | sort | uniq -c | sort -rn | head"
    quit
}

# Re-enable timedata mode for plotting with timestamps and set timefmt to match CSV
set xdata time
set timefmt "%Y-%m-%d %H:%M:%S"

# Apply axis limits if provided
if (exists("cpu_min") && exists("cpu_max")) {
    set yrange [cpu_min:cpu_max]
}
if (exists("mem_min") && exists("mem_max")) {
    set y2range [mem_min:mem_max]
}

# Add labels showing computed stats (mean and max) on the plot using screen coordinates
# CPU label on left, MEM label on right
set label 1 sprintf("CPU mean: %.2f m\\nCPU max: %.2f m", CPU_mean, CPU_max) at screen 0.02, 0.92 left
set label 2 sprintf("Mem mean: %.2f Mi\\nMem max: %.2f Mi", MEM_mean, MEM_max) at screen 0.98, 0.92 right

# Choose colors for stat lines (distinct from data)
cpu_mean_color = "dark-red"
cpu_max_color  = "orange"
mem_mean_color = "dark-blue"
mem_max_color  = "cyan"

# Plot data + stat horizontal lines. Constants (CPU_mean etc.) are plotted as functions (constant over x).
# CPU mean/max plotted on left y axis; MEM mean/max on right y2 axis (use 'axes x1y2').
plot tmpfile using 1:2 with lines lw 2 lc rgb "red" title "CPU (m)", \
     CPU_mean with lines lw 1 lc rgb cpu_mean_color title sprintf("CPU mean: %.2f m", CPU_mean), \
     CPU_max with lines lw 1 lc rgb cpu_max_color title sprintf("CPU max: %.2f m", CPU_max), \
     tmpfile using 1:3 axes x1y2 with lines lw 2 lc rgb "blue" title "Memory (MiB)", \
     MEM_mean axes x1y2 with lines lw 1 lc rgb mem_mean_color title sprintf("Mem mean: %.2f Mi", MEM_mean), \
     MEM_max axes x1y2 with lines lw 1 lc rgb mem_max_color title sprintf("Mem max: %.2f Mi", MEM_max)
