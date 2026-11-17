#!/usr/bin/env python3
"""Build combined Xray-link, Sing-box and Mihomo subscriptions from trusted XHTTP instances."""
import json, os, re, sys, urllib.parse

BASE = sys.argv[1] if len(sys.argv) > 1 else '/etc'
OUT = sys.argv[2] if len(sys.argv) > 2 else ''
# Compatibility is based on instance identity and validated state, not a brittle version allowlist.

def enc(v): return urllib.parse.quote(str(v), safe='')
def safe(v): return re.sub(r'[^A-Za-z0-9_.-]+', '-', str(v)).strip('-') or 'node'
def client_path(s):
    p=s.get('PATH_VALUE','')
    if s.get('PATH_STYLE','legacy') == 'uuid-suffix' and (s.get('PROTOCOL','').startswith(('xhttp-','ws-'))): p += s.get('UUID','')
    return p

def node_from(d):
    marker=os.path.join(d,'.xhttp-manager-instance'); state=os.path.join(d,'state.json')
    if not os.path.isfile(marker) or not os.path.isfile(state): return None
    try:
        lines=open(marker,encoding='utf-8').read().splitlines()
        vals={x.split(': ',1)[0]:x.split(': ',1)[1] for x in lines if ': ' in x}
        ident=os.path.basename(d)
        if vals.get('XHTTP Manager instance') != ident: return None
        s=json.load(open(state,encoding='utf-8'))
        for k in ('PROTOCOL','DOMAIN','PORT','UUID'):
            if not s.get(k): return None
        if not str(s['PORT']).isdigit() or not (1 <= int(s['PORT']) <= 65535): return None
        if not re.fullmatch(r'[0-9a-fA-F-]{16,64}',str(s['UUID'])): return None
        s['_id']=ident; s['_path']=client_path(s); return s
    except Exception: return None

def build(s, variant=None):
    p=s['PROTOCOL']; server=s['DOMAIN']; uid=s['UUID']; path=s['_path']; tunnel=s.get('TUNNEL')=='yes'
    port=443 if tunnel else int(s['PORT']); sec='tls' if (tunnel or s.get('SECURITY')=='tls') else ('reality' if s.get('SECURITY')=='reality' else 'none')
    suffix = ('-'+variant.upper()) if variant else ''
    tag=safe(s['_id']+'-'+p+'-'+server+'-'+str(port)+suffix)
    alpn = (['h2','http/1.1'] if variant=='h2' else ['h3']) if variant else ['h2','http/1.1']
    net='xhttp' if p.startswith('xhttp-') else ('ws' if p.startswith('ws-') else ('grpc' if p=='grpc-tls' else 'httpupgrade'))
    q={'encryption':'none','type':net}
    if sec!='none': q['security']=sec
    if sec in ('tls','reality'):
        q['sni']=s.get('REALITY_SNI') if sec=='reality' else server
        q['fp']='chrome'
    if sec=='tls' and (variant or tunnel): q['alpn']=','.join(alpn)
    if sec=='reality': q.update({'pbk':s.get('REALITY_PUBLIC',''),'sid':s.get('REALITY_SHORT_ID','')})
    if net=='xhttp':
        q.update({'host':server,'path':path,'mode':'packet-up' if tunnel else 'auto'})
        if s.get('XMUX_ENABLED')=='yes':
            extra={'scMaxEachPostBytes':1000000,'scMinPostsIntervalMs':30,'xmux':{'maxConcurrency':s.get('XMUX_MAX_CONCURRENCY','16-32'),'maxConnections':int(s.get('XMUX_MAX_CONNECTIONS',0) or 0),'cMaxReuseTimes':s.get('XMUX_C_REUSE','64-128'),'hMaxRequestTimes':s.get('XMUX_H_REQUESTS','600-900'),'hMaxReusableSecs':s.get('XMUX_H_SECS','1800-3000'),'hKeepAlivePeriod':0}}
            q['extra']=json.dumps(extra,separators=(',',':'))
    elif net=='ws': q.update({'host':server,'path':path})
    elif net=='grpc': q['serviceName']='grpc'
    elif net=='httpupgrade': q['path']=path
    link=f"vless://{uid}@{server}:{port}?"+urllib.parse.urlencode(q,safe=',')+'#'+enc(tag)
    xray={'tag':tag,'protocol':'vless','settings':{'vnext':[{'address':server,'port':port,'users':[{'id':uid,'encryption':'none'}]}]},'streamSettings':{'network':net,'security':sec}}
    st=xray['streamSettings']
    if sec=='tls': st['tlsSettings']={'serverName':server,'alpn':alpn,'fingerprint':'chrome'}
    if sec=='reality': st['realitySettings']={'serverName':s.get('REALITY_SNI',''),'publicKey':s.get('REALITY_PUBLIC',''),'shortId':s.get('REALITY_SHORT_ID',''),'fingerprint':'chrome'}
    if net=='xhttp':
        st['xhttpSettings']={'host':server,'path':path,'mode':'packet-up' if tunnel else 'auto'}
        if s.get('XMUX_ENABLED')=='yes':
            st['xhttpSettings']['extra']={'scMaxEachPostBytes':1000000,'scMinPostsIntervalMs':30,'xmux':{'maxConcurrency':s.get('XMUX_MAX_CONCURRENCY','16-32'),'maxConnections':int(s.get('XMUX_MAX_CONNECTIONS',0) or 0),'cMaxReuseTimes':s.get('XMUX_C_REUSE','64-128'),'hMaxRequestTimes':s.get('XMUX_H_REQUESTS','600-900'),'hMaxReusableSecs':s.get('XMUX_H_SECS','1800-3000'),'hKeepAlivePeriod':0}}
    elif net=='ws': st['wsSettings']={'path':path,'headers':{'Host':server}}
    elif net=='grpc': st['grpcSettings']={'serviceName':'grpc'}
    elif net=='httpupgrade': st['httpupgradeSettings']={'path':path,'host':server}
    sb={'type':'vless','tag':tag,'server':server,'server_port':port,'uuid':uid}
    if sec=='tls': sb['tls']={'enabled':True,'server_name':server,'alpn':alpn,'utls':{'enabled':True,'fingerprint':'chrome'}}
    if sec=='reality': sb['tls']={'enabled':True,'server_name':s.get('REALITY_SNI',''),'utls':{'enabled':True,'fingerprint':'chrome'},'reality':{'enabled':True,'public_key':s.get('REALITY_PUBLIC',''),'short_id':s.get('REALITY_SHORT_ID','')}}
    if net=='xhttp': sb['transport']={'type':'xhttp','host':server,'path':path,'mode':'packet-up' if tunnel else 'auto'}
    elif net=='ws': sb['transport']={'type':'ws','path':path,'headers':{'Host':server}}
    elif net=='grpc': sb['transport']={'type':'grpc','service_name':'grpc'}
    elif net=='httpupgrade': sb['transport']={'type':'httpupgrade','host':server,'path':path}
    cp={'name':tag,'type':'vless','server':server,'port':port,'uuid':uid,'encryption':'','udp':True,'network':net}
    if sec in ('tls','reality'):
        cp['tls']=True; cp['servername']=server if sec=='tls' else s.get('REALITY_SNI',''); cp['client-fingerprint']='chrome'
    if sec=='tls' and (variant or tunnel): cp['alpn']=alpn
    if sec=='reality': cp['reality-opts']={'public-key':s.get('REALITY_PUBLIC',''),'short-id':s.get('REALITY_SHORT_ID','')}
    if net=='xhttp':
        cp['xhttp-opts']={'host':server,'path':path,'mode':'packet-up' if tunnel else 'auto'}
        if s.get('XMUX_ENABLED')=='yes':
            cp['xhttp-opts'].update({'sc-max-each-post-bytes':1000000,'sc-min-posts-interval-ms':30,'reuse-settings':{'max-concurrency':s.get('XMUX_MAX_CONCURRENCY','16-32'),'c-max-reuse-times':s.get('XMUX_C_REUSE','64-128'),'h-max-request-times':s.get('XMUX_H_REQUESTS','600-900'),'h-max-reusable-secs':s.get('XMUX_H_SECS','1800-3000'),'h-keep-alive-period':0}})
    elif net=='ws': cp['ws-opts']={'path':path,'headers':{'Host':server}}
    elif net=='grpc': cp['grpc-opts']={'grpc-service-name':'grpc'}
    elif net=='httpupgrade': cp['http-upgrade-opts']={'path':path,'host':server}
    return link,xray,sb,cp

def main():
    if not OUT: raise SystemExit('output directory required')
    nodes=[]
    for name in sorted(os.listdir(BASE)):
        if name=='xhttp' or re.fullmatch(r'xhttp-[0-9]+',name):
            n=node_from(os.path.join(BASE,name))
            if n: nodes.append(n)
    if not nodes: raise SystemExit('未检测到可订阅节点；请先部署至少一个有效节点。')
    built=[]
    for n in nodes:
        if n['PROTOCOL'] in ('xhttp-tls','xhttp-tunnel'):
            built.extend([build(n,'h2'),build(n,'h3')])
        else:
            built.append(build(n))
    links=[x[0] for x in built]; xray=[x[1] for x in built]; sing=[x[2] for x in built]; clash=[x[3] for x in built]
    tags=[x['tag'] for x in sing]
    os.makedirs(OUT,mode=0o700,exist_ok=True)
    with open(os.path.join(OUT,'jhsub.txt'),'w',encoding='utf-8') as f: f.write('\n'.join(links)+'\n')
    with open(os.path.join(OUT,'sbox.json'),'w',encoding='utf-8') as f:
        json.dump({'log':{'level':'warn'},'inbounds':[{'type':'mixed','tag':'mixed-in','listen':'127.0.0.1','listen_port':2080}], 'outbounds':sing+[{'type':'direct','tag':'direct'},{'type':'selector','tag':'select','outbounds':tags+['direct'],'default':tags[0]}], 'route':{'final':'select'}},f,ensure_ascii=False,indent=2)
    # JSON is a valid YAML 1.2 document, avoiding unsafe hand-built YAML quoting.
    with open(os.path.join(OUT,'clmi.yaml'),'w',encoding='utf-8') as f:
        json.dump({'mixed-port':7890,'allow-lan':False,'mode':'rule','log-level':'warning','proxies':clash,'proxy-groups':[{'name':'XHTTP-ALL','type':'select','proxies':tags+['DIRECT']}], 'rules':['MATCH,XHTTP-ALL']},f,ensure_ascii=False,indent=2)
    with open(os.path.join(OUT,'xray.json'),'w',encoding='utf-8') as f:
        json.dump({'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':10808,'protocol':'socks','settings':{'auth':'noauth','udp':True}}], 'outbounds':xray+[{'protocol':'freedom','tag':'direct'}]},f,ensure_ascii=False,indent=2)
    for n in nodes: print(f"收录实例：{n['_id']} | {n['PROTOCOL']} | {n['DOMAIN']}:{n['PORT']} | {n['_path']}")
    print(f'共扫描 {len(nodes)} 个实例，生成 {len(built)} 条客户端节点；Clash/Mihomo、Sing-box、聚合链接均已更新。')
if __name__=='__main__': main()
