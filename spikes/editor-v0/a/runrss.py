import subprocess, sys, resource, time
t=time.time(); r=subprocess.run(sys.argv[1:]); print('exit',r.returncode,'wall_s %.1f'%(time.time()-t),'maxrss_MB',resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss//1024)
