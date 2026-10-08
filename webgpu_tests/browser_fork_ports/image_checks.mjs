// Pixel checks shared by browser capture and native fixture calibration.
const countColor=(image,rect,match)=>{let count=0;for(let y=rect[1];y<rect[3];y++)for(let x=rect[0];x<rect[2];x++){const i=(y*image.width+x)*4;if(match(image.data[i],image.data[i+1],image.data[i+2]))count++;}return count;};
const red=(r,g,b)=>r>160&&r>g*2&&r>b*2,blue=(r,g,b)=>b>160&&b>r*2&&b>g*2;
export function verifyImages(images){
  const checks=[];const check=(name,passed,detail)=>checks.push({name,passed,detail});
  const font=images.font;
  check('canvas_dimensions',Object.values(images).every(i=>i.width===512&&i.height===384),Object.fromEntries(Object.entries(images).map(([n,i])=>[n,[i.width,i.height]])));
  for(const [row,label] of ['mask','lcd','msdf'].entries()){const pixels=countColor(font,[0,row*88,400,(row+1)*88],red);check('font_'+label,pixels>150,pixels);}
  const svg=countColor(font,[0,264,400,352],blue);check('font_svg_retains_blue_under_red_modulation',svg>200,svg);
  const sdf=images.canvas_sdf;
  check('canvas_sdf_inside',countColor(sdf,[70,70,90,90],red)>350);
  check('canvas_sdf_outside',countColor(sdf,[10,10,30,30],blue)>350);
  const before=images.ssr_off,after=images.ssr_on;let reflected=0,sum=0;
  for(let y=212;y<384;y++)for(let x=0;x<512;x++){const i=(y*512+x)*4,delta=after.data[i]-before.data[i];if(delta>6&&after.data[i]>after.data[i+1]*1.15){reflected++;sum+=delta/255;}}
  check('ssr_visible_source',countColor(before,[0,0,512,384],red)>300);
  check('ssr_red_reflection',reflected>80&&sum>10,{pixels:reflected,sum});
  function contrast(image,cx){let sum=0,squares=0,count=0;for(let y=152;y<232;y++)for(let x=cx-20;x<cx+20;x++){const a=image.data[(y*512+x)*4]/255;sum+=a;squares+=a*a;count++;}return Math.sqrt(Math.max(0,squares/count-(sum/count)**2));}
  const sharp=[128,256,384].map(x=>contrast(images.dof_off,x)),blur=[128,256,384].map(x=>contrast(images.dof_on,x));
  check('dof_sharp_panels',sharp.every(c=>c>0.35),sharp);
  check('dof_near_blurred',blur[0]<sharp[0]*0.7,{sharp,blur});
  check('dof_focus_preserved',blur[1]>sharp[1]*0.8,{sharp,blur});
  check('dof_far_blurred',blur[2]<sharp[2]*0.7,{sharp,blur});
  return checks;
}
