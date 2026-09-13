#!/usr/bin/env python3
# Virtual keyboard via /dev/uinput: send key codes given on argv, 0.4 s apart. Root only.
import fcntl, os, struct, sys, time
UI_SET_EVBIT=0x40045564; UI_SET_KEYBIT=0x40045565; UI_DEV_SETUP=0x405c5503; UI_DEV_CREATE=0x5501; UI_DEV_DESTROY=0x5502
fd=os.open('/dev/uinput',os.O_WRONLY|os.O_NONBLOCK)
fcntl.ioctl(fd,UI_SET_EVBIT,1)
codes=[int(c) for c in sys.argv[1:]]
for c in set(codes): fcntl.ioctl(fd,UI_SET_KEYBIT,c)
fcntl.ioctl(fd,UI_DEV_SETUP,struct.pack('HHHH80sI',3,0x1234,0x5678,1,b'test-clicker',0))
fcntl.ioctl(fd,UI_DEV_CREATE); time.sleep(3)   # let the daemon's rescan pick it up
def ev(t,c,v): os.write(fd,struct.pack('llHHi',0,0,t,c,v))
for c in codes:
    ev(1,c,1); ev(0,0,0); time.sleep(0.05); ev(1,c,0); ev(0,0,0); time.sleep(0.4)
time.sleep(1); fcntl.ioctl(fd,UI_DEV_DESTROY); os.close(fd); print('injected',codes)
