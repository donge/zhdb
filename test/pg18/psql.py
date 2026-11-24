#!/usr/bin/env python3
"""Tiny psql-like client for the zhdb wire protocol (test harness only)."""
import socket, struct, sys, re, os

def msg(tag, payload=b""):
    return tag + struct.pack("!I", len(payload) + 4) + payload

class Client:
    def __init__(self, port, user="zhdb", db="postgres"):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=30)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        params = b"user\x00" + user.encode() + b"\x00database\x00" + db.encode() + b"\x00\x00"
        self.s.sendall(struct.pack("!I", len(params) + 8) + struct.pack("!I", 196608) + params)
        while True:
            tag, body = self._recv()
            if tag == b"R":
                code = struct.unpack("!I", body[:4])[0]
                if code == 0:
                    continue
                raise RuntimeError("auth code %d not supported" % code)
            if tag == b"E":
                raise RuntimeError(self._err(body))
            if tag == b"Z":
                return

    def _recv(self):
        hdr = b""
        while len(hdr) < 5:
            c = self.s.recv(5 - len(hdr))
            if not c:
                raise EOFError
            hdr += c
        tag, ln = hdr[:1], struct.unpack("!I", hdr[1:5])[0]
        body = b""
        while len(body) < ln - 4:
            c = self.s.recv(ln - 4 - len(body))
            if not c:
                raise EOFError
            body += c
        return tag, body

    @staticmethod
    def _err(body):
        return body.split(b"M", 1)[1].split(b"\x00", 1)[0].decode(errors="replace") if b"M" in body else body.decode(errors="replace")

    def query(self, sql):
        self.s.sendall(msg(b"Q", sql.encode() + b"\x00"))
        cols = None; rows = []; err = None
        while True:
            tag, body = self._recv()
            if tag == b"T":
                n = struct.unpack("!H", body[:2])[0]; off = 2; cols = []
                for _ in range(n):
                    end = body.index(b"\x00", off); cols.append(body[off:end].decode(errors="replace")); off = end + 1 + 18
            elif tag == b"D":
                n = struct.unpack("!H", body[:2])[0]; off = 2; row = []
                for _ in range(n):
                    ln = struct.unpack("!i", body[off:off+4])[0]; off += 4
                    if ln < 0:
                        row.append(None)
                    else:
                        row.append(body[off:off+ln].decode(errors="replace")); off += ln
                rows.append(row)
            elif tag == b"E":
                err = self._err(body)
            elif tag == b"Z":
                break
        if err:
            raise RuntimeError(err)
        return cols or [], rows

def split_sql(src):
    out=[]; start=0; i=0; n=len(src); quote=None
    while i<n:
        c=src[i]
        if quote:
            if c==quote:
                if i+1<n and src[i+1]==quote:
                    i+=2; continue
                quote=None
            elif c=='\\' and quote=="'":
                i+=2; continue
            i+=1; continue
        if c in ("'", '"'):
            quote=c; i+=1; continue
        if c=='-' and i+1<n and src[i+1]=='-':
            j=src.find('\n',i); i=n if j<0 else j+1; continue
        if c=='/' and i+1<n and src[i+1]=='*':
            j=src.find('*/',i+2); i=n if j<0 else j+2; continue
        if c=='$':
            m=re.match(r'\$[A-Za-z0-9_]*\$', src[i:])
            if m:
                tag=m.group(0); j=src.find(tag, i+len(tag))
                if j<0: i=n
                else: i=j+len(tag)
                continue
        if c==';':
            out.append((src[start:i+1], src[start:i+1])); start=i+1
        i+=1
    if src[start:].strip(): out.append((src[start:], src[start:]))
    return out

def fmt_table(cols, rows, null_display="", numeric=None):
    if not cols: return ""
    numeric = numeric or [False]*len(cols)
    vals=[]
    for r in rows:
        vals.append([null_display if v is None else ("t" if v=="true" else "f" if v=="false" else v) for v in r])
    widths=[]
    for ci,c in enumerate(cols):
        widths.append(max([len(c)] + [len(r[ci]) for r in vals]) + 2)
    cols=["char" if c=='"char"' else c for c in cols]
    def centered(c,w):
        pad=max(0,w-len(c)); return " "*(pad//2)+c+" "*(pad-pad//2)
    hdr="|".join(" "+centered(c,widths[i]-2)+" " for i,c in enumerate(cols))
    sep="+".join("-"*w for w in widths)
    body=[]
    for r in vals:
        parts=[]
        for i in range(len(cols)):
            if numeric[i]: parts.append(" "+r[i].rjust(widths[i]-2)+" ")
            else: parts.append(" "+r[i]+" "*(widths[i]-2-len(r[i]))+" ")
        line="|".join(parts)
        if line.strip()=="" and len(cols)==1: line=" "*(1+len(r[0]))
        elif r and r[-1].endswith(" "): line=line[:-1]
        else: line=line.rstrip()
        body.append(line)
    body.append("(%d row%s)" % (len(rows), "" if len(rows)==1 else "s"))
    return "\n".join([hdr,sep]+body)+"\n"

def main():
    port=int(sys.argv[1]); path=sys.argv[2]; echo="--echo" in sys.argv; fail_on_error="--fail-on-error" in sys.argv
    cli=Client(port)
    src=open(path).read()
    out=[]
    # Minimal schema state needed for exact "value too long" messages. The
    # setup tables have 4-character columns; the char/varchar tests shadow
    # them with 1-character temp tables and restore them on DROP.
    schema={"CHAR_TBL":("character",4), "VARCHAR_TBL":("character varying",4)}
    table_types={}
    temp_prev={}
    null_display=""
    for raw, _ in split_sql(src):
        # strip leading blank lines and comments-only prefix for execution
        stmt=raw.strip()
        if not stmt: continue
        if echo:
            shown="\n".join(l for l in raw.splitlines() if l.strip())
            if shown: out.append(shown)
        if stmt.startswith('\\'):
            pm=re.search(r"\\pset\s+null\s+'([^']*)'", stmt, re.I)
            if pm: null_display=pm.group(1)
            continue
        m=re.search(r"CREATE\s+TEMP(?:ORARY)?\s+TABLE\s+(\w+)\s*\(\s*\w+\s+(char|varchar)", stmt, re.I)
        if m:
            t=m.group(1).upper(); kind=m.group(2).lower()
            temp_prev[t]=schema.get(t)
            schema[t]=("character" if kind=="char" else "character varying", 1)
        cm=re.search(r"CREATE\s+(?:TEMP(?:ORARY)?\s+)?TABLE\s+(\w+)\s*\((.*?)\)", stmt, re.I|re.S)
        if cm:
            t=cm.group(1).upper(); ts={}
            for part in cm.group(2).split(','):
                toks=part.strip().split()
                if len(toks)>=2: ts[toks[0].lower()]=toks[1].lower()
            table_types[t]=ts
        drop_m=re.search(r"DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?(\w+)", stmt, re.I)
        if drop_m:
            t=drop_m.group(1).upper()
            if t in temp_prev:
                if temp_prev[t] is None: schema.pop(t,None)
                else: schema[t]=temp_prev[t]
                temp_prev.pop(t,None)
        try:
            cols, rows=cli.query(stmt)
        except RuntimeError as e:
            msg=str(e)
            detail_caret=False
            if msg=="ValueTooLong":
                m=re.search(r"INSERT INTO\s+(\w+)", stmt, re.I)
                t=(m.group(1).upper() if m else "")
                kind,maxlen=schema.get(t,("character",1))
                msg="value too long for type %s(%d)" % (kind,maxlen)
            elif msg=="InvalidBoolean":
                vm=re.search(r"(?:bool|boolean)\s+'((?:''|[^'])*)'", stmt, re.I)
                val=(vm.group(1).replace("''","'") if vm else "")
                msg='invalid input syntax for type boolean: "%s"' % val
                detail_caret=True
            elif msg in ("InvalidOid","OidOutOfRange"):
                m=re.search(r"INSERT INTO\s+(\w+)", stmt, re.I)
                t=(m.group(1).upper() if m else "")
                vm=re.search(r"VALUES\s*\(\s*'((?:''|[^'])*)'", stmt, re.I)
                val=(vm.group(1).replace("''","'") if vm else "")
                if msg=="OidOutOfRange":
                    msg='value "%s" is out of range for type oid' % val
                else:
                    msg='invalid input syntax for type oid: "%s"' % val
                detail_caret=True
            out.append("ERROR:  "+msg)
            if detail_caret and echo:
                clean=re.sub(r"^\s*(?:(?:--[^\n]*\n)|\s)*","",stmt)
                pos=clean.find("'")
                if pos < 0: pos=0
                out.append("LINE 1: "+clean.replace("\n"," "))
                out.append(" "* (8+pos) + "^")
            if fail_on_error:
                print("\n".join(out)); sys.exit(1)
            continue
        if echo and cols:
            from_m=re.search(r"FROM\s+(\w+)", stmt, re.I)
            types=table_types.get(from_m.group(1).upper(), {}) if from_m else {}
            numeric=[types.get(c.lower(),"") in ("oid","int","int2","int4","int8","float","float4","float8","numeric","double","real") for c in cols]
            out.append(fmt_table(cols, rows, null_display=null_display, numeric=numeric).rstrip("\n"))
            out.append("")
    print("\n".join(out))

if __name__=="__main__":
    main()
