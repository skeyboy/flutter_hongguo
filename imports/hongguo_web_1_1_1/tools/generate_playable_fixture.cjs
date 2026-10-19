// Developer-only synthetic H.264/AAC fixture. No ffmpeg dependency in the app.
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),dir=path.join(root,'packages/hongguo_core/test/fixtures');
const sourceRoot=path.resolve(process.env.HONGGUO_NODE_ROOT || "/Users/lee/Downloads/hongguo-web-1.1.1-macOS-arm");
const M=require(path.join(sourceRoot,'server/src/core/mp4.js')),C=require(path.join(sourceRoot,'server/src/util/crypto.js')),S=require(path.join(sourceRoot,'server/src/core/spade.js'));
const clear=path.join(dir,'playable-clear.mp4');
const result=spawnSync('ffmpeg',['-v','error','-y','-f','lavfi','-i','testsrc2=size=320x240:rate=15','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','3','-c:v','libx264','-pix_fmt','yuv420p','-profile:v','baseline','-c:a','aac','-movflags','+faststart',clear],{stdio:'inherit'});
if(result.status!==0)throw Error('ffmpeg synthetic fixture generation failed');
let source=fs.readFileSync(clear);
const top=M.parseBoxes(source,0,source.length),moov=top.find(b=>b.type==='moov'),analysis=M.analyzeEncryptedTracks(source);
const trackBoxes=moov.children.filter(b=>b.type==='trak');
const tracks=new Map(trackBoxes.map((b,i)=>[b.start,analysis.tracks[i]]));
function u32(n){const b=Buffer.alloc(4);b.writeUInt32BE(n);return b;}
function box(t,p){return Buffer.concat([u32(8+p.length),Buffer.from(t),p]);}
function iv(track,index){const b=Buffer.alloc(16);b.writeBigUInt64BE((BigInt(track.trackId)<<32n)+BigInt(index+1));return b;}
for(const t of analysis.tracks)for(let i=0;i<t.sampleCount;i++) {
 const off=t.offsets[i],size=t.sizes[i];
 C.aes128Ctr(Buffer.from(S.TRUTH[0][1],'hex'),iv(t,i),source.subarray(off,off+size)).copy(source,off);
}
function rebuild(b,track,delta){
 if(b.type==='trak')track=tracks.get(b.start);
 if(b.type==='stco'||b.type==='co64'){
  const out=Buffer.from(source.subarray(b.start,b.end())),n=out.readUInt32BE(12),width=b.type==='stco'?4:8;
  for(let i=0;i<n;i++) {
   const p=16+i*width;
   if(width===4){const v=out.readUInt32BE(p);if(v<moov.end())throw Error('Expected faststart layout');out.writeUInt32BE(v+delta,p);}
   else{const v=out.readBigUInt64BE(p);out.writeBigUInt64BE(v+BigInt(delta),p);}
  }
  return out;
 }
 if(b.type==='stsd'){
  const entries=b.children.map(entry=>{
   const raw=source.subarray(entry.start,entry.end());
   const tenc=box('tenc',Buffer.concat([Buffer.alloc(4),Buffer.from([0,0,1,16]),Buffer.alloc(16,0x11)]));
   const sinf=box('sinf',Buffer.concat([box('frma',Buffer.from(entry.type)),box('schm',Buffer.concat([Buffer.alloc(4),Buffer.from('cenc'),u32(0x10000)])),box('schi',tenc)]));
   return box(track.handler==='vide'?'encv':'enca',Buffer.concat([raw.subarray(8),sinf]));
  });
  return box('stsd',Buffer.concat([source.subarray(b.start+8,b.start+16),...entries]));
 }
 if(!b.children.length)return source.subarray(b.start,b.end());
 const parts=b.children.map(c=>rebuild(c,track,delta));
 if(b.type==='stbl')parts.push(box('senc',Buffer.concat([Buffer.alloc(4),u32(track.sampleCount),...Array.from({length:track.sampleCount},(_,i)=>iv(track,i))])));
 return box(b.type,Buffer.concat(parts));
}
let rebuilt=rebuild(moov,null,0);const delta=rebuilt.length-moov.size;rebuilt=rebuild(moov,null,delta);
const encrypted=Buffer.concat(top.map(b=>b.type==='moov'?rebuilt:source.subarray(b.start,b.end())));
fs.writeFileSync(path.join(dir,'playable-encrypted.mp4'),encrypted);
console.log(JSON.stringify({clear:fs.statSync(clear).size,encrypted:encrypted.length,tracks:analysis.tracks.map(t=>({handler:t.handler,samples:t.sampleCount}))}));
