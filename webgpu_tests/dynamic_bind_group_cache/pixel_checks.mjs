// Independent screenshot oracle: eight material colors and eight vacated positions.
export function checkPhase(image, phase) {
  if (!Number.isInteger(phase) || phase < 0 || phase >= 12) throw new Error('Invalid phase');
  if (image.width !== 96 || image.height !== 64) throw new Error(`Wrong dimensions ${image.width}x${image.height}`);
  const colors = [[255,0,0],[0,255,0],[0,0,255],[255,255,255]];
  const checks = [];
  for (let tile = 0; tile < 8; tile++) {
    for (const empty of [false,true]) {
      const samplePhase = phase + Number(empty);
      const x = Math.round(8 + (tile % 4) * 24 + (samplePhase % 2 ? 9.6 : 0));
      const y = tile < 4 ? 16 : 48;
      const expected = empty ? [0,0,0] : colors[(tile+phase)%4];
      let passed = true;
      for (let py=y-1;py<=y+1;py++) for(let px=x-1;px<=x+1;px++) {
        const offset=(py*image.width+px)*4;
        passed &&= expected.every((value,channel)=>Math.abs(image.data[offset+channel]-value)<=5);
      }
      checks.push({name:`phase_${phase}_${empty?'empty':'tile'}_${tile}`,passed});
    }
  }
  return checks;
}
