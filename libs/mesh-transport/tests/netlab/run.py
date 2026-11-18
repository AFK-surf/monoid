# Four isolated network namespaces. A bounded Unix datagram bridge is their only
# link: it forwards real UDP packets, enforcing edges, delay and packet loss.
import os,sys,socket,subprocess,selectors,threading,queue,time,json,heapq
from collections import deque
ROOT="."
SCENARIO=os.environ.get("MESH_SCENARIO","soft")
def addr(i,kind=0): return (f'127.0.0.{i+10}',24000+i+1000*kind)
def uds(i): return f'{ROOT}/node-{i}.sock'
def sock():
    s=socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,1024*1024)
    return s
if len(sys.argv)>1:
    i=int(sys.argv[1]); subprocess.run(['ip','link','set','lo','up'],check=True)
    bridge=sock(); bridge.bind(uds(i)); bridge.setblocking(False)
    watch=selectors.DefaultSelector(); watch.register(bridge,selectors.EVENT_READ,'bridge')
    udp={}
    for j in range(4):
        if j==i: continue
        for kind in range(2 if SCENARIO.startswith('native') else 1):
            s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(addr(j,kind)); s.setblocking(False)
            udp[j,kind]=s; watch.register(s,selectors.EVENT_READ,(j,kind))
    pending=deque()
    p=subprocess.Popen(['./netlab',str(i)])
    try:
        while p.poll() is None:
            for event,_ in watch.select(.02):
                if event.data=='bridge':
                    packet=bridge.recv(65536)
                    try: udp[packet[0],packet[1]].sendto(packet[2:],addr(i,packet[1]))
                    except BlockingIOError:
                        if os.environ.get("MESH_TRACE_ROUTING"): print("BRIDGE_UDP_SEND_DROP",i,packet[0],packet[1],flush=True)
                else:
                    data,source=event.fileobj.recvfrom(65536)
                    j,kind=event.data
                    if source!=addr(i,kind): raise RuntimeError(f'unexpected sender {source}')
                    if len(pending)>=4096: raise RuntimeError('bridge input overflow')
                    pending.append(bytes([i,j,kind])+data)
            while pending:
                try: bridge.sendto(pending[0],ROOT+'/hub.sock'); pending.popleft()
                except BlockingIOError: break
        sys.exit(p.returncode)
    finally:
        if p.poll() is None: p.terminate(); p.wait()
# Parent bridge has no IP listeners. All network namespaces have loopback only.
for path in ['hub.sock']+[f'node-{i}.sock' for i in range(4)]:
    if os.path.exists(path): os.unlink(path)
hub=sock(); hub.bind(ROOT+'/hub.sock'); hub.setblocking(False)
watch=selectors.DefaultSelector(); watch.register(hub,selectors.EVENT_READ)
q=queue.Queue(); processes={}; logs={}; ready=set(); samples=[]; quic=[]; events=[]; routes=[]; scheduled=[]; counts={}; stats={}; serial=0
began=time.monotonic(); fault=None; connected_ms=None; verified=None; peak_scheduled=0

def start(i):
    p=subprocess.Popen(['unshare','-Urn','python3','run.py',str(i)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1,start_new_session=True)
    processes[i]=p; logs[i]=open(f'node-{i}.log','w')
    def read():
        for line in p.stdout:
            logs[i].write(line); logs[i].flush(); q.put((i,line.strip()))
        q.put((i,'EXIT'))
    threading.Thread(target=read,daemon=True).start()
try:
    for i in [1,2,3]: start(i)
    source_started=False; done=False
    while not done:
        now=time.monotonic()
        if now-began>120: raise TimeoutError('isolated network test deadline')
        while not q.empty():
            i,line=q.get_nowait(); print(i,line,flush=True)
            if line.startswith('MESH_DIAG '): print('DIAG_RECEIPT',int((now-began)*1000),i,line,flush=True)
            if line==f'READY {i}': ready.add(i)
            if line.startswith('SELECTED '): events.append({'node':i,'circuit':line.split()[1],'at_ms':int((now-began)*1000)})
            if line.startswith('CONNECTED '): connected_ms=int(line.split()[1])
            if line.startswith('VERIFIED '): verified=list(map(int,line.split()[1:]))
            if line.startswith('QUIC '):
                _,seq,selected,path_id,circuit,rtt=line.split()
                quic.append({'node':i,'sequence':int(seq),'selected':selected=='true','path_id':path_id,'circuit':circuit,'rtt_ms':int(rtt),'at_ms':int((now-began)*1000)})
            if line.startswith('ROUTE '):
                _,seq,circuit,path=line.split(' ',3)
                routes.append({'node':i,'sequence':int(seq),'circuit':circuit,'path':json.loads(path)})
            if i==0 and line.startswith('SAMPLE '):
                _,seq,ms,path=line.split(' ',3)
                row={'sequence':int(seq),'ms':int(ms),'path':json.loads(path),'at_ms':int((now-began)*1000)}
                samples.append(row)
                if os.environ.get('MESH_TRACE_ROUTING'):
                    print('BRIDGE_STATS',int(seq),json.dumps({'at_ms':row['at_ms'],'scheduled':len(scheduled),'links':stats}),flush=True)
                if int(seq)==3 and SCENARIO not in ('chain','native-baseline'):
                    if not SCENARIO.startswith('native'): assert row['path']==[0,3],row
                    fault=now
                    print('FAULT direct delay200ms loss5%',flush=True)
            if line=='EXIT':
                code=processes[i].wait()
                if code: raise RuntimeError(f'node {i} failed: {code}')
                if i==0: done=True
        if not source_started and {1,2,3}.issubset(ready):
            start(0); source_started=True
        for event,_ in watch.select(.002):
            while True:
                try: packet=hub.recv(65536)
                except BlockingIOError: break
                a,b,kind=packet[:3]; edge=(a,b); k=f'{a}-{b}-{kind}'
                counts[k]=counts.get(k,0)+1
                row=stats.setdefault(k,{'received':0,'forwarded':0,'dropped':0,'denied':0,'injected_loss':0,'queue_retries':0,'bytes':0})
                row['received']+=1
                direct={a,b}=={0,3}
                allowed=(direct if kind==1 else abs(a-b)==1) if SCENARIO.startswith('native') else ((direct and SCENARIO!='chain') or abs(a-b)==1)
                impaired=fault is not None and (SCENARIO!='flap' or time.monotonic()-fault<1.5)
                lost=direct and impaired and counts[k]%20==0
                if not allowed or lost:
                    row['dropped']+=1
                    row['denied' if not allowed else 'injected_loss']+=1
                    continue
                if len(scheduled)>=4096: raise RuntimeError('scheduled bridge queue overflow')
                delay=.2 if direct and impaired else (0 if direct else .005)
                serial+=1
                heapq.heappush(scheduled,(time.monotonic()+delay,serial,b,bytes([a,kind])+packet[3:],k))
                peak_scheduled=max(peak_scheduled,len(scheduled))
        now=time.monotonic()
        while scheduled and scheduled[0][0]<=now:
            _,_,b,data,k=heapq.heappop(scheduled)
            try:
                hub.sendto(data,uds(b)); stats[k]['forwarded']+=1; stats[k]['bytes']+=len(data)-2
            except BlockingIOError:
                stats[k]['queue_retries']+=1
                serial+=1
                heapq.heappush(scheduled,(time.monotonic()+.001,serial,b,data,k))
            except (FileNotFoundError,ConnectionRefusedError): stats[k]['dropped']+=1
    assert len(samples)==35
    if SCENARIO=='flap': assert all(s['path']==[0,3] for s in samples),samples
    elif not SCENARIO.startswith('native'): assert sum(s['path']==[0,1,2,3] for s in samples if s['sequence']>=15)>=3,samples
    print('COMPLETE '+SCENARIO+'; quantitative acceptance is separate',flush=True)
finally:
    json.dump({'peak_scheduled':peak_scheduled,'scenario':SCENARIO,'connected_ms':connected_ms,'verified':verified,'fault_ms':None if fault is None else int((fault-began)*1000),'samples':samples,'links':stats,'quic':quic,'routes':routes,'events':events},open('result.json','w'),indent=2)
    import signal
    for p in processes.values():
        if p.poll() is None: os.killpg(p.pid,signal.SIGTERM)
    for p in processes.values():
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
