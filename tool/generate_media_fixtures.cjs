#!/usr/bin/env node
// Offline samples only. ffmpeg is a development fixture tool, not an app dependency.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');
const sourceRoot=process.argv[2];
if(!sourceRoot)throw Error('Usage: node tool/generate_media_fixtures.cjs /path/to/hongguo-web');
const fixture=require(path.resolve(sourceRoot,'server/src/mp4-fixture.js'));
const mp4=require(path.resolve(sourceRoot,'server/src/core/mp4.js'));
const crypto=require('node:crypto');
const testKey='287216bfa89e662a0f748120c305e199';
const out=path.resolve(__dirname,'../packages/core/test/fixtures/media');
fs.mkdirSync(out,{recursive:true});
for(const [name,build] of [['head',fixture.buildMinimalEncryptedMp4],['tail',fixture.buildTailMoovEncryptedMp4]]){
 const bytes=build();
 const track=mp4.analyzeEncryptedTracks(bytes).tracks[0];
 fixture.plainSamples().forEach((plain,i)=>{
   const cipher=crypto.createCipheriv('aes-128-ctr',Buffer.from(testKey,'hex'),Buffer.from(track.ivs[i],'hex'));
   Buffer.concat([cipher.update(plain),cipher.final()]).copy(bytes,track.offsets[i]);
 });
 // The original synthetic fixture labels AVC bytes as HEVC. Correct the test
 // description/configuration, leaving ciphertext/sample tables unchanged.
 bytes.write('avc1',bytes.indexOf(Buffer.from('frma'))+4,'latin1');
 const at=bytes.indexOf(Buffer.from('hvcC'));
 bytes.write('avcC',at,'latin1');bytes[at+4+4]=3;
 fs.writeFileSync(path.join(out,`${name}.cenc.mp4`),bytes);
}
fs.writeFileSync(path.join(out,'synthetic.json'),JSON.stringify({
 key:testKey,plainSamples:fixture.plainSamples().map(b=>b.toString('base64'))
},null,2));
function ff(...args){cp.execFileSync('ffmpeg',['-hide_banner','-loglevel','error','-y',...args],{stdio:'inherit'});}
const clear=path.join(out,'clear.mp4'),enc=path.join(out,'real.cenc.mp4');
ff('-f','lavfi','-i','testsrc=size=160x288:rate=12','-f','lavfi','-i','sine=frequency=440:sample_rate=44100',
 '-t','1.5','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-movflags','+faststart',clear);
ff('-i',clear,'-map','0','-c','copy','-encryption_scheme','cenc-aes-ctr',
 '-encryption_key','287216bfa89e662a0f748120c305e199','-encryption_kid','112233445566778899aabbccddeeff00',enc);
fs.writeFileSync(path.join(out,'real.json'),JSON.stringify({key:'287216bfa89e662a0f748120c305e199'}));
console.log('Generated synthetic head/tail + real H.264/AAC CENC fixtures offline.');
