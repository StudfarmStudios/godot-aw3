import assert from 'node:assert/strict';
import {checkPhase} from './pixel_checks.mjs';
const colors=[[255,0,0],[0,255,0],[0,0,255],[255,255,255]];
for(let phase=0;phase<12;phase++) {
  const image={width:96,height:64,data:Buffer.alloc(96*64*4)};
  for(let tile=0;tile<8;tile++) {
    const centerX=Math.round(8+(tile%4)*24+(phase%2?9.6:0)),centerY=tile<4?16:48;
    for(let y=centerY-1;y<=centerY+1;y++)for(let x=centerX-1;x<=centerX+1;x++) {
      colors[(tile+phase)%4].forEach((value,channel)=>{image.data[(y*96+x)*4+channel]=value;});
    }
  }
  assert.equal(checkPhase(image,phase).filter(check=>check.passed).length,16);
  image.data.fill(0);
  assert.equal(checkPhase(image,phase).filter(check=>!check.passed).length,8);
}
assert.throws(()=>checkPhase({width:95,height:64},0),/Wrong dimensions/);
assert.throws(()=>checkPhase({width:96,height:64},12),/Invalid phase/);
console.log('DYNAMIC_BIND_GROUP pixel oracle controls passed26');
