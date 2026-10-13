#include "sgn_render.h"
#include <string.h>
static float absf(float v){return v<0.0f?-v:v;}
float sg_target_mpp(const SGScene *s){
 float m=s?(float)s->zoom_mpp_milli/1000.0f:2.0f;
 return m<0.05f?0.05f:m>50.0f?50.0f:m;
}
float sg_zoom_factor(int step){
 if(step<SG_ZOOM_STEP_MIN)step=SG_ZOOM_STEP_MIN;
 if(step>SG_ZOOM_STEP_MAX)step=SG_ZOOM_STEP_MAX;
 float f=1.0f;
 for(int i=0;i<step;i++)f*=1.25f;
 for(int i=0;i>step;i--)f/=1.25f;
 return f<0.4f?0.4f:f>4.0f?4.0f:f;
}
void sg_anim_reset(SGAnim *a){memset(a,0,sizeof *a);}
void sg_anim_head_mode(SGAnim *a,bool enabled){
 if(a->head_mode==enabled)return;
 a->head_mode=enabled;a->head_sample=false;
}
bool sg_anim_head_sample(SGAnim *a,float degrees,uint32_t sampled_at,uint32_t now){
 if(!a->head_mode||!(degrees>=0.0f&&degrees<360.0f)||
    (uint32_t)(now-sampled_at)>SG_HEAD_MAX_AGE_MS)return false;
 if(a->head_sample&&(int32_t)(sampled_at-a->head_at)<=0)return false;
 a->head_heading=degrees;a->head_at=sampled_at;a->head_sample=true;return true;
}
bool sg_anim_head_fresh(const SGAnim *a,uint32_t now){
 return a->head_mode&&a->head_sample&&(uint32_t)(now-a->head_at)<=SG_HEAD_MAX_AGE_MS;
}
bool sg_anim_zoom(SGAnim *a,int step,uint32_t now){
 if(!a||!step)return false;
 int z=a->zoom_step-(step>0?1:-1); /* zoom in = smaller mpp multiplier */
 if(z<SG_ZOOM_STEP_MIN)z=SG_ZOOM_STEP_MIN;
 if(z>SG_ZOOM_STEP_MAX)z=SG_ZOOM_STEP_MAX;
 a->zoom_step=(int8_t)z;a->zoom_at=now;a->zoomed=true; /* at the limit: the bar still flashes as feedback */
 return true;
}
uint32_t sg_scale_metres(float mpp,int *px){
 static const uint32_t nice[]={5,10,20,50,100,200,500,1000,2000,5000,10000,20000,50000,100000};
 if(!(mpp>0.0f))mpp=1.0f;
 uint32_t m=nice[0];
 for(unsigned i=0;i<sizeof nice/sizeof nice[0];i++){m=nice[i];if((float)m/mpp>=36.0f)break;}
 float p=(float)m/mpp;if(p>120.0f)p=120.0f;
 if(px)*px=(int)(p+0.5f);
 return m;
}
static void dr_target(const SGScene *s,uint32_t rx,uint32_t now,float *x,float *y){
 *x=(float)s->pos_x;*y=(float)s->pos_y;
 if(s->flags&SG_F_ARRIVED)return;
 uint32_t dt=now-rx;if(dt>SG_DR_MAX_MS)dt=SG_DR_MAX_MS; /* never extrapolate more than 3 s */
 /* heading_cd: clockwise from north; local frame x=east, y=north (0.5 m units). */
 float d=(float)s->speed_cms*(float)dt/50000.0f,h=(float)s->heading_cd/100.0f;
 *x+=d*sg_sin(h);*y+=d*sg_cos(h);
}
static void anim_key(const SGAnim *a,uint32_t gen,int32_t key[7]){
 float k=2.0f/a->mpp; /* quarter-pixel position key */
 key[0]=(int32_t)(a->x*k);key[1]=(int32_t)(a->y*k);key[2]=(int32_t)(a->heading*10.0f);key[3]=(int32_t)(a->rot*10.0f);
 key[4]=(int32_t)(a->mpp*1000.0f);key[5]=(int32_t)gen;key[6]=a->scale?a->zoom_step+100:0;
}
bool sg_anim_step(SGAnim *a,const SGScene *s,uint32_t gen,uint32_t rx,uint32_t now){
 float tx=0.0f,ty=0.0f,th=0.0f,tm=sg_target_mpp(s)*sg_zoom_factor(a->zoom_step);
 tm=tm<0.05f?0.05f:tm>200.0f?200.0f:tm;
 if(s){dr_target(s,rx,now,&tx,&ty);th=(float)s->heading_cd/100.0f;}
 /* GPS course remains the sole input to dr_target above. Turning one's head
  * rotates the view and its upward chevron, never the extrapolated position. */
 if(a->head_mode)th=sg_anim_head_fresh(a,now)?a->head_heading:(a->init?a->heading:0.0f);
 if(!a->init||(!s&&a->generation)){
  a->init=true;a->x=tx;a->y=ty;a->ox=a->oy=0.0f;a->heading=th;a->rot=th;a->mpp=tm;
  a->last=now;a->generation=gen;a->key[5]=-1;
 }else if(s&&gen!=a->generation){
  /* New fix: keep what is on screen and decay the correction (no jump). A
   * large jump (re-route, re-origin) is applied immediately. */
  a->ox=a->x-tx;a->oy=a->y-ty;
  if(absf(a->ox)>400.0f||absf(a->oy)>400.0f)a->ox=a->oy=0.0f;
  a->generation=gen;
 }
 uint32_t dt=now-a->last;if(dt>1000u)dt=1000u;a->last=now;
 float keep=sg_exp_neg((float)dt/SG_TAU_MS),alpha=1.0f-keep,hkeep=sg_exp_neg((float)dt/SG_HEADING_TAU_MS);
 a->ox*=keep;a->oy*=keep;
 if(absf(a->ox)<0.05f)a->ox=0.0f;
 if(absf(a->oy)<0.05f)a->oy=0.0f;
 float dh=sg_wrap180(th-a->heading);
 a->heading=absf(dh)<0.05f?th:sg_wrap360(a->heading+(1.0f-hkeep)*dh);
 a->rot=a->heading; /* view-up: chevron stays up for both head and course modes */
 float dm=tm-a->mpp;a->mpp=absf(dm)<tm*0.001f?tm:a->mpp+alpha*dm;
 a->x=tx+a->ox;a->y=ty+a->oy;
 a->scale=a->zoomed&&(uint32_t)(now-a->zoom_at)<SG_SCALE_SHOW_MS;
 if(!a->scale)a->zoomed=false;
 int32_t key[7];anim_key(a,gen,key);
 return memcmp(key,a->key,sizeof key)!=0;
}
void sg_anim_drawn(SGAnim *a){anim_key(a,a->generation,a->key);}
/* ---- turn icons: 44x44 grid, polyline shaft + filled arrow head ---- */
typedef struct { uint8_t n,head;int8_t p[7][2]; } Path;
static const Path P_STRAIGHT={2,1,{{22,42},{22,14}}};
static const Path P_RIGHT={3,1,{{15,42},{15,22},{30,22}}};
static const Path P_SLIGHT={3,1,{{15,42},{15,29},{28,16}}};
static const Path P_SHARP={3,1,{{13,42},{13,12},{27,26}}};
static const Path P_UTURN={7,1,{{30,42},{30,18},{28,11},{22,8},{16,11},{14,18},{14,26}}};
static const Path P_RB_IN={2,0,{{22,42},{22,27}}};
static const Path P_RB_OUT={2,1,{{28,11},{34,5}}};
static const Path P_POLE={2,0,{{11,42},{11,4}}};
static const Path P_MAIN={2,0,{{14,44},{14,0}}};
static const Path P_ENTER={3,1,{{36,42},{25,29},{25,14}}};
static const Path P_EXIT={3,1,{{14,40},{14,30},{29,15}}};
static const Path P_UNKNOWN={5,0,{{22,4},{40,22},{22,40},{4,22},{22,4}}};
static void path(const SGClip *c,int ox,int oy,const Path *p,bool mirror,int width,uint8_t g){
 float x[7],y[7];
 for(unsigned i=0;i<p->n;i++){x[i]=(float)(ox+(mirror?44-p->p[i][0]:p->p[i][0]));y[i]=(float)(oy+p->p[i][1]);}
 for(unsigned i=1;i<p->n;i++){sg_line(c,x[i-1],y[i-1],x[i],y[i],width,g);if(i+1<p->n)sg_disc(c,(int)x[i],(int)y[i],width/2,g);}
 if(!p->head||p->n<2)return;
 float dx=x[p->n-1]-x[p->n-2],dy=y[p->n-1]-y[p->n-2],len=sg_sqrt(dx*dx+dy*dy);
 if(len<0.5f)return;
 dx/=len;dy/=len;float ex=x[p->n-1],ey=y[p->n-1];
 sg_tri(c,ex+dx*9.0f,ey+dy*9.0f,ex-dx*3.0f-dy*9.0f,ey-dy*3.0f+dx*9.0f,ex-dx*3.0f+dy*9.0f,ey-dy*3.0f-dx*9.0f,g,false);
}
void sg_draw_icon(const SGClip *c,int x,int y,unsigned icon,uint8_t g){
 uint8_t dim=(uint8_t)(g*2/5);
 switch(icon){
 case 1:path(c,x,y,&P_STRAIGHT,false,5,g);break;
 case 2:case 3:path(c,x,y,&P_RIGHT,icon==2,5,g);break;
 case 4:case 5:path(c,x,y,&P_SLIGHT,icon==4,5,g);break;
 case 6:case 7:path(c,x,y,&P_SHARP,icon==6,5,g);break;
 case 8:path(c,x,y,&P_UTURN,false,5,g);break;
 case 9:sg_ring(c,x+22,y+17,9,3,g);path(c,x,y,&P_RB_IN,false,5,g);path(c,x,y,&P_RB_OUT,false,4,g);break;
 case 10:path(c,x,y,&P_POLE,false,3,g);sg_tri(c,(float)(x+12),(float)(y+4),(float)(x+36),(float)(y+11),(float)(x+12),(float)(y+19),g,false);
  sg_line(c,(float)(x+4),(float)(y+42),(float)(x+20),(float)(y+42),3,g);break;
 case 11:path(c,x,y,&P_MAIN,false,3,dim);path(c,x,y,&P_ENTER,false,5,g);break;
 case 12:path(c,x,y,&P_MAIN,false,3,dim);path(c,x,y,&P_EXIT,false,5,g);break;
 default:path(c,x,y,&P_UNKNOWN,false,3,g);sg_disc(c,x+22,y+22,3,g);break;
 }
}
void sg_draw_panel(uint8_t *fb,const SGScene *s,bool dim){
 SGClip c={fb,SG_W,0,0,SG_PANEL_W,SG_H};
 sg_fill(&c,0);
 uint8_t g=dim?110:255;
 if(s)sg_draw_icon(&c,2,3,s->icon,g);
 sg_box(&c,SG_PANEL_W-1,4,1,SG_H-8,70);
 sg_box(&c,4,108,SG_PANEL_W-10,1,50);
}
/* ---- transient scale bar: 7-segment digits + 'k'/'m' strokes, 7x10 cells ---- */
static const uint8_t SEG[7][4]={{0,0,6,0},{6,0,6,5},{6,5,6,10},{0,10,6,10},{0,5,0,10},{0,0,0,5},{0,5,6,5}};
static const uint8_t DIGIT[10]={0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f}; /* bit i = SEG[i] (a..g) */
static void glyph(const SGClip *c,int x,int y,char ch,uint8_t g){
 if(ch=='k'){sg_line(c,(float)x,(float)y,(float)x,(float)(y+10),2,g);sg_line(c,(float)x,(float)(y+7),(float)(x+5),(float)(y+4),2,g);
  sg_line(c,(float)(x+2),(float)(y+6),(float)(x+5),(float)(y+10),2,g);return;}
 uint8_t m=ch=='m'?0x54:(ch>='0'&&ch<='9')?DIGIT[ch-'0']:0; /* m = c+e+g, plus the middle stem */
 for(unsigned i=0;i<7;i++)if(m&(1u<<i))sg_line(c,(float)(x+SEG[i][0]),(float)(y+SEG[i][1]),(float)(x+SEG[i][2]),(float)(y+SEG[i][3]),2,g);
 if(ch=='m')sg_line(c,(float)(x+3),(float)(y+5),(float)(x+3),(float)(y+10),2,g);
}
static void draw_scale(const SGClip *c,float mpp,bool dim){
 int px=0;uint32_t m=sg_scale_metres(mpp,&px);
 char t[12];unsigned n=0,v=m>=1000u?m/1000u:m;char d[8];unsigned k=0;
 do{d[k++]=(char)('0'+v%10u);v/=10u;}while(v&&k<sizeof d);
 while(k)t[n++]=d[--k];
 if(m>=1000u)t[n++]='k';
 t[n++]='m';
 int right=SG_W-8,tw=(int)n*10-3,w=(px>tw?px:tw)+8;
 uint8_t g=dim?120:230;
 sg_box(c,right-w+4,SG_H-27,w,25,0);
 for(unsigned i=0;i<n;i++)glyph(c,right-tw+(int)i*10,SG_H-25,t[i],g);
 sg_box(c,right-px,SG_H-8,px,3,g);
 sg_box(c,right-px,SG_H-12,2,7,g);sg_box(c,right-2,SG_H-12,2,7,g);
}
static float gray(unsigned base,bool dim){return (float)(dim?base/2u:base);}
unsigned sg_feature_layout(const SGScene *s,const SGAnim *a,int badge_w,SGFeatureLabel out[SG_FEATURE_VISIBLE]){
 if(!s||!a||!a->init||a->mpp<=0)return 0;
 unsigned count=0;size_t at=s->features_off;
 float sn=sg_sin(a->rot),cs=sg_cos(a->rot),k=0.5f/a->mpp;
 for(unsigned i=0;i<s->feature_count&&count<SG_FEATURE_VISIBLE;i++){
  const uint8_t *p=s->raw+at;unsigned len=p[1];at+=6+len;
  float dx=((float)sg_i16(p+2)-a->x)*k,dy=((float)sg_i16(p+4)-a->y)*k;
  float fx=SG_MAP_CX+dx*cs-dy*sn,fy=SG_MAP_CY-dx*sn-dy*cs;
  if(fx<SG_PANEL_W+12||fx>SG_W-24||fy<12||fy>SG_H-24)continue;
  int x=(int)(fx+0.5f)-9,y=(int)(fy+0.5f)-9,w=19;
  if(p[0]==3){
   if(!len)continue;
   unsigned width=0;for(unsigned j=0;j<len;j++)if(p[6+j]<128)width+=9;else if(p[6+j]>=192)width+=16;
   w=(int)width+8;if(w>136)w=136;
   x=(int)(fx+0.5f)-w/2;
  }
  if(x<SG_PANEL_W+2||x+w>SG_W-2)continue;
  if(x<SG_MAP_CX+17&&x+w>SG_MAP_CX-17&&y<SG_MAP_CY+15&&y+20>SG_MAP_CY-15)continue;
  if(badge_w&&x<SG_PANEL_W+badge_w+8&&y<27)continue;
  if(a->scale&&x+w>SG_W-125&&y+20>SG_H-30)continue;
  bool overlaps=false;for(unsigned j=0;j<count;j++)if(x<out[j].x+out[j].w+4&&x+w+4>out[j].x&&y<out[j].y+23&&y+23>out[j].y){overlaps=true;break;}
  if(overlaps)continue;
  SGFeatureLabel *f=&out[count++];f->x=x;f->y=y;f->w=w;f->kind=p[0];
  memcpy(f->text,p+6,len);f->text[len]=0;
 }
 return count;
}
static void draw_features(const SGClip *c,const SGScene *s,const SGAnim *a,bool dim,int badge_w){
 SGFeatureLabel f[SG_FEATURE_VISIBLE];unsigned n=sg_feature_layout(s,a,badge_w,f);
 uint8_t g=dim?110:220;
 for(unsigned i=0;i<n;i++){
  int x=f[i].x,y=f[i].y;
  if(f[i].kind==3)sg_box(c,x,y,f[i].w,19,0);
  if(f[i].kind==1){
   const int vx[8]={5,13,18,18,13,5,0,0},vy[8]={0,0,5,13,18,18,13,5};
   for(unsigned j=0;j<8;j++)sg_tri(c,x+9,y+9,x+vx[j],y+vy[j],x+vx[(j+1)%8],y+vy[(j+1)%8],0,true);
   for(unsigned j=0;j<8;j++)sg_line(c,x+vx[j],y+vy[j],x+vx[(j+1)%8],y+vy[(j+1)%8],1,g);
   /* Compact 3x5 STOP lettering retains the sign's actual meaning. */
   const uint16_t letters[4]={0x79cf,0x7492,0x7b6f,0x7be4};
   for(unsigned ch=0;ch<4;ch++)for(unsigned row=0;row<5;row++)for(unsigned col=0;col<3;col++)
    if(letters[ch]&(1u<<(14-row*3-col)))sg_box(c,x+2+(int)ch*4+(int)col,y+7+(int)row,1,1,g);
  }else if(f[i].kind==2){
   sg_frame(c,x+4,y,11,19,g);
   for(int j=0;j<3;j++)sg_ring(c,x+9,y+4+j*6,2,1,g);
  }
 }
}
void sg_draw_map(uint8_t *fb,const SGScene *s,const SGAnim *a,bool dim,int badge_w,SGDrawStats *st){
 SGClip c={fb,SG_W,SG_PANEL_W,0,SG_W,SG_H};
 SGDrawStats z={0,0,0,0};if(!st)st=&z;memset(st,0,sizeof *st);
 sg_fill(&c,0);
 float sn=sg_sin(a->rot),cs=sg_cos(a->rot),k=0.5f/a->mpp,ax=a->x,ay=a->y;
#define TX(wx,wy) ((float)SG_MAP_CX+(((float)(wx)-ax)*k)*cs-(((float)(wy)-ay)*k)*sn)
#define TY(wx,wy) ((float)SG_MAP_CY-((((float)(wx)-ax)*k)*sn+(((float)(wy)-ay)*k)*cs))
 if(s){
  static const uint8_t shade[4]={115,150,190,225},width[4]={1,2,2,3};
  unsigned budget=SG_POINT_BUDGET;
  unsigned route=s->route_n<budget?s->route_n:budget;budget-=route;
  /* Roads: important classes first while the point budget lasts. */
  for(int cls=3;cls>=0;cls--){
   size_t at=s->roads_off;
   for(unsigned i=0;i<s->road_count;i++){
    uint8_t rc=s->raw[at],n=s->raw[at+1];const uint8_t *p=s->raw+at+2;at+=2u+4u*n;
    if(rc!=(uint8_t)cls)continue;
    if(n>budget){st->skipped++;continue;}
    budget-=n;st->points+=n;st->roads++;
    float px=TX(sg_i16(p),sg_i16(p+2)),py=TY(sg_i16(p),sg_i16(p+2));
    for(unsigned j=1;j<n;j++){
     float qx=TX(sg_i16(p+4*j),sg_i16(p+4*j+2)),qy=TY(sg_i16(p+4*j),sg_i16(p+4*j+2));
     st->steps+=sg_line(&c,px,py,qx,qy,width[cls],(uint8_t)gray(shade[cls],dim));px=qx;py=qy;
    }
   }
  }
  const uint8_t *p=s->raw+s->route_off;uint8_t rg=(uint8_t)gray(255,dim);
  st->points+=route;
  if(route){
   float px=TX(sg_i16(p),sg_i16(p+2)),py=TY(sg_i16(p),sg_i16(p+2));
   for(unsigned j=1;j<route;j++){
    float qx=TX(sg_i16(p+4*j),sg_i16(p+4*j+2)),qy=TY(sg_i16(p+4*j),sg_i16(p+4*j+2));
    st->steps+=sg_line(&c,px,py,qx,qy,4,rg);
    if(qx>-8.0f&&qx<(float)(SG_W+8)&&qy>-8.0f&&qy<(float)(SG_H+8))sg_disc(&c,(int)qx,(int)qy,1,rg);
    px=qx;py=qy;
   }
  }
  float mx=TX(s->man_x,s->man_y),my=TY(s->man_x,s->man_y);
  if(!(s->flags&SG_F_ARRIVED)&&mx>(float)(SG_PANEL_W-10)&&mx<(float)(SG_W+10)&&my>-10.0f&&my<(float)(SG_H+10))
   sg_ring(&c,(int)mx,(int)my,7,2,rg);
 }
#undef TX
#undef TY
 /* Vehicle chevron: dark halo then bright body, rotated by heading-rotation. */
 float h=a->heading-a->rot,hs=sg_sin(h),hc=sg_cos(h);
 static const float shape[4][2]={{0.0f,-11.0f},{-8.0f,8.0f},{0.0f,3.0f},{8.0f,8.0f}};
 for(unsigned pass=0;pass<2;pass++){
  float sc=pass?1.0f:1.45f,vx[4],vy[4];
  for(unsigned i=0;i<4;i++){
   float x=shape[i][0]*sc,y=shape[i][1]*sc;
   vx[i]=(float)SG_MAP_CX+x*hc-y*hs;vy[i]=(float)SG_MAP_CY+x*hs+y*hc;
  }
  uint8_t g=pass?(uint8_t)gray(255,dim):0;
  sg_tri(&c,vx[0],vy[0],vx[1],vy[1],vx[2],vy[2],g,true);
  sg_tri(&c,vx[0],vy[0],vx[2],vy[2],vx[3],vy[3],g,true);
 }
 if(a->rot>0.5f&&a->rot<359.5f){ /* heading-up: small north pointer, top right */
  float nx=-sg_sin(a->rot),ny=-sg_cos(a->rot),cx=(float)(SG_W-14),cy=14.0f;
  sg_ring(&c,(int)cx,(int)cy,10,1,60);
  sg_tri(&c,cx+nx*8.0f,cy+ny*8.0f,cx-ny*4.0f,cy+nx*4.0f,cx+ny*4.0f,cy-nx*4.0f,220,true);
  sg_line(&c,cx,cy,cx-nx*7.0f,cy-ny*7.0f,2,90);
 }
 draw_features(&c,s,a,dim,badge_w);
 if(a->scale)draw_scale(&c,a->mpp,dim);
 if(badge_w>0){sg_box(&c,SG_PANEL_W+4,3,badge_w,21,0);sg_frame(&c,SG_PANEL_W+4,3,badge_w,21,170);}
}
/* ---- label text ---- */
static size_t put(char *o,size_t cap,size_t at,const char *s){while(*s&&at+1<cap)o[at++]=*s++;if(cap)o[at<cap?at:cap-1]=0;return at;}
static size_t num(char *o,size_t cap,size_t at,uint32_t v){
 char t[10];unsigned n=0;do{t[n++]=(char)('0'+v%10u);v/=10u;}while(v);
 while(n&&at+1<cap)o[at++]=t[--n];if(cap)o[at<cap?at:cap-1]=0;return at;
}
static size_t dist(char *o,size_t cap,size_t at,uint32_t m){
 if(m<1000u){if(m>=100u)m=(m+5u)/10u*10u;if(m>=1000u)return put(o,cap,at,"1.0km");at=num(o,cap,at,m);return put(o,cap,at,"m");}
 if(m<9950u){uint32_t d=(m+50u)/100u;at=num(o,cap,at,d/10u);at=put(o,cap,at,".");at=num(o,cap,at,d%10u);return put(o,cap,at,"km");}
 if(m>=999500u)return put(o,cap,at,"999km");
 at=num(o,cap,at,(m+500u)/1000u);return put(o,cap,at,"km");
}
size_t sg_fmt_distance(char *o,size_t cap,uint32_t m){if(!o||!cap)return 0;o[0]=0;return dist(o,cap,0,m);}
size_t sg_fmt_bottom(char *o,size_t cap,const SGScene *s){
 if(!o||!cap)return 0;o[0]=0;if(!s)return 0;
 size_t at=put(o,cap,0,"余");at=dist(o,cap,at,s->remain_dist_m);
 if(s->eta[0]){at=put(o,cap,at," ");return put(o,cap,at,s->eta);}
 if(!s->remain_time_s)return at;
 uint32_t min=(s->remain_time_s+59u)/60u;at=put(o,cap,at," ");
 if(min>=60u){at=num(o,cap,at,min/60u);at=put(o,cap,at,"时");min%=60u;}
 at=num(o,cap,at,min);return put(o,cap,at,"分");
}
