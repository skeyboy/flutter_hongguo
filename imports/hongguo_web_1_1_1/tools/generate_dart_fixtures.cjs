// Offline reference vectors. Does not call upstream endpoints.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const sourceRoot=path.resolve(process.env.HONGGUO_NODE_ROOT || "/Users/lee/Downloads/hongguo-web-1.1.1-macOS-arm");
const target = path.join(root, 'packages/hongguo_core/test/fixtures');
fs.mkdirSync(target, {recursive:true});
let cursor=0;
const fixedCrypto = Object.assign({},crypto, {
 randomBytes(n) { return Buffer.from(Array.from({length:n},()=> (cursor++*73+41)&255)); },
 randomInt(n) {return ((cursor++*7919+12345)>>>0)%n;}
});
const fixedDate = class extends Date { static now(){return 1780000000123;} };
const file = path.join(sourceRoot,'server/src/core/pure-sign.js');
const moduleObj = {exports:{}};
const {createRequire}=require('node:module'); const localRequire=createRequire(file);
vm.runInNewContext(fs.readFileSync(file,'utf8'),{require:n=>n==='crypto'?fixedCrypto:localRequire(n),module:moduleObj,Buffer,Date:fixedDate});
const cases=[];
for (let i=0;i<48;i++) {
 const url='https://example.test/path?device_id=1234567890123456789&version_name=7.1.3.32&q='+encodeURIComponent(i%2?'红果 * +':'')+'&_rticket='+i;
 const body=i%8===0?Buffer.alloc(0):i%3===0?null:Buffer.from(i%3===1?'{}':'{"query":"红果","id":"7693917197759958040"}');
 cursor=18; // nonce consumed once at module initialization
 const ts=i<24?1780000000+i:[0,1,0x7fffffff,0x80000000,0xffffffff,0x100000000][(i-24)%6];
 cases.push({url,body:body?.toString('base64')??null,ts,branch:moduleObj.exports.branchOf(url,body,ts),headers:moduleObj.exports.sign(url,body,ts)});
}
fs.writeFileSync(path.join(target,'sign.json'),JSON.stringify(cases,null,2));
const spade = require(path.join(sourceRoot,'server/src/core/spade.js'));
fs.writeFileSync(path.join(target,'spade.json'),JSON.stringify(spade.TRUTH));
const f=require(path.join(sourceRoot,'server/src/mp4-fixture.js'));
fs.writeFileSync(path.join(target,'head.mp4'),f.buildMinimalEncryptedMp4());
fs.writeFileSync(path.join(target,'tail.mp4'),f.buildTailMoovEncryptedMp4());
fs.writeFileSync(path.join(target,'mp4.json'),JSON.stringify({key:f.fixtureKeyHex(),samples:f.plainSamples().map(x=>x.toString('hex'))}));
const constants=Buffer.from('4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58','hex');
const seed=Buffer.from('deterministic url seed');
const h=crypto.createHash('sha512').update(Buffer.concat([crypto.createHash('sha512').update(seed).digest(),constants])).digest();
const plain='https://video.fqnovelvod.com/test.mp4?name=红果&a=1';
const c=crypto.createCipheriv('aes-128-cbc',h.subarray(0,16),h.subarray(16,32));
fs.writeFileSync(path.join(target,'url.json'),JSON.stringify({seed:seed.toString('base64'),plain,value:Buffer.concat([Buffer.from([168,0,1,0]),c.update(plain),c.final()]).toString('base64')}));
console.log('Generated 48 signature vectors, 5 Spade truths, URL and head/tail MP4 fixtures.');
const mp4=require(path.join(sourceRoot,'server/src/core/mp4.js'));
const rekeyed=Buffer.from(f.buildMinimalEncryptedMp4());
const analysis=mp4.analyzeEncryptedTracks(rekeyed);
for(const track of analysis.tracks) {
  mp4.decryptTrack(rekeyed,track,f.fixtureKeyHex(),null);
  for(let i=0;i<track.sampleCount;i++) {
    const off=track.offsets[i],size=track.sizes[i];
    const cipher=crypto.createCipheriv('aes-128-ctr',Buffer.from(spade.TRUTH[0][1],'hex'),mp4.counterFor(track,null,i));
    Buffer.concat([cipher.update(rekeyed.subarray(off,off+size)),cipher.final()]).copy(rekeyed,off);
  }
}
fs.writeFileSync(path.join(target,'spade-media.mp4'),rekeyed);
