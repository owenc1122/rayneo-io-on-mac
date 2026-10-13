#include "sgn_raster.h"
#include <string.h>
#define SG_FLOAT_LIMIT 1.0e7f
static bool finite(float v){return v>-SG_FLOAT_LIMIT&&v<SG_FLOAT_LIMIT;} /* false for NaN/inf */
float sg_wrap360(float d){
 if(!finite(d))return 0.0f;
 int k=(int)(d/360.0f);d-=(float)k*360.0f;
 if(d<0.0f)d+=360.0f;
 if(d>=360.0f)d-=360.0f;
 return d;
}
float sg_wrap180(float d){d=sg_wrap360(d);return d>180.0f?d-360.0f:d;}
float sg_sin(float deg){
 float x=sg_wrap180(deg);
 if(x>90.0f)x=180.0f-x;else if(x<-90.0f)x=-180.0f-x;
 float r=x*0.017453292f,r2=r*r;
 return r*(1.0f-r2/6.0f*(1.0f-r2/20.0f*(1.0f-r2/42.0f*(1.0f-r2/72.0f))));
}
float sg_cos(float deg){return sg_sin(deg+90.0f);}
float sg_sqrt(float v){
 if(!(v>0.0f))return 0.0f;
 if(!finite(v))return 3162.3f;
 union{float f;uint32_t u;} b={v};b.u=(b.u>>1)+0x1fc00000u;float g=b.f;
 for(unsigned i=0;i<4;i++)g=0.5f*(g+v/g);
 return g;
}
float sg_exp_neg(float x){
 if(!(x>0.0f))return 1.0f;
 if(x>30.0f)return 0.0f;
 int k=(int)(x*1.44269504f);float f=x-(float)k*0.693147181f;
 float e=1.0f-f*(1.0f-f/2.0f*(1.0f-f/3.0f*(1.0f-f/4.0f*(1.0f-f/5.0f*(1.0f-f/6.0f)))));
 while(k-->0)e*=0.5f;
 return e;
}
static int clampi(int v,int lo,int hi){return v<lo?lo:v>hi?hi:v;}
static int flo(float v){int i=(int)v;return (float)i>v?i-1:i;} /* |v| < 1e7 */
void sg_span(const SGClip *c,int y,int xa,int xb,uint8_t g,bool set){
 if(y<c->y0||y>=c->y1)return;
 if(xa>xb){int t=xa;xa=xb;xb=t;}
 if(xb<c->x0||xa>=c->x1)return;
 xa=clampi(xa,c->x0,c->x1-1);xb=clampi(xb,c->x0,c->x1-1);
 uint8_t *p=c->px+(long)y*c->stride;
 if(set){memset(p+xa,g,(size_t)(xb-xa+1));return;}
 for(int x=xa;x<=xb;x++)if(p[x]<g)p[x]=g;
}
static void vspan(const SGClip *c,int x,int ya,int yb,uint8_t g){
 if(x<c->x0||x>=c->x1)return;
 if(ya>yb){int t=ya;ya=yb;yb=t;}
 if(yb<c->y0||ya>=c->y1)return;
 ya=clampi(ya,c->y0,c->y1-1);yb=clampi(yb,c->y0,c->y1-1);
 for(int y=ya;y<=yb;y++){uint8_t *p=c->px+(long)y*c->stride+x;if(*p<g)*p=g;}
}
void sg_fill(const SGClip *c,uint8_t g){for(int y=c->y0;y<c->y1;y++)sg_span(c,y,c->x0,c->x1-1,g,true);}
void sg_box(const SGClip *c,int x,int y,int w,int h,uint8_t g){
 if(w<=0||h<=0)return;
 for(int yy=y;yy<y+h;yy++)sg_span(c,yy,x,x+w-1,g,true);
}
void sg_frame(const SGClip *c,int x,int y,int w,int h,uint8_t g){
 if(w<=0||h<=0)return;
 sg_span(c,y,x,x+w-1,g,true);sg_span(c,y+h-1,x,x+w-1,g,true);
 for(int yy=y+1;yy<y+h-1;yy++){sg_span(c,yy,x,x,g,true);sg_span(c,yy,x+w-1,x+w-1,g,true);}
}
enum {IN=0,LEFT=1,RIGHT=2,TOP=4,BOTTOM=8};
static unsigned code(float x,float y,float l,float t,float r,float b){
 unsigned k=IN;if(x<l)k|=LEFT;else if(x>r)k|=RIGHT;if(y<t)k|=TOP;else if(y>b)k|=BOTTOM;return k;
}
unsigned sg_line(const SGClip *c,float ax,float ay,float bx,float by,int width,uint8_t g){
 if(!finite(ax)||!finite(ay)||!finite(bx)||!finite(by))return 0;
 width=clampi(width,1,15);
 float m=(float)(width/2+1),l=(float)c->x0-m,t=(float)c->y0-m,r=(float)(c->x1-1)+m,b=(float)(c->y1-1)+m;
 unsigned ka=code(ax,ay,l,t,r,b),kb=code(bx,by,l,t,r,b);
 for(unsigned guard=0;;guard++){
  if(!(ka|kb))break;
  if((ka&kb)||guard>8)return 0;
  unsigned k=ka?ka:kb;float x,y;
  if(k&TOP){x=ax+(bx-ax)*(t-ay)/(by-ay);y=t;}
  else if(k&BOTTOM){x=ax+(bx-ax)*(b-ay)/(by-ay);y=b;}
  else if(k&RIGHT){y=ay+(by-ay)*(r-ax)/(bx-ax);x=r;}
  else {y=ay+(by-ay)*(l-ax)/(bx-ax);x=l;}
  if(!finite(x)||!finite(y))return 0;
  if(k==ka){ax=x;ay=y;ka=code(ax,ay,l,t,r,b);}else{bx=x;by=y;kb=code(bx,by,l,t,r,b);}
 }
 /* Now within the clip rectangle grown by the brush margin: int conversion is safe. */
 int x0=(int)(ax+(ax<0?-0.5f:0.5f)),y0=(int)(ay+(ay<0?-0.5f:0.5f));
 int x1=(int)(bx+(bx<0?-0.5f:0.5f)),y1=(int)(by+(by<0?-0.5f:0.5f));
 int dx=x1>x0?x1-x0:x0-x1,dy=y1>y0?y0-y1:y1-y0,sx=x0<x1?1:-1,sy=y0<y1?1:-1,e=dx+dy;
 bool xmajor=dx>=-dy;int major=xmajor?dx:-dy,span=width;
 if(width>1&&major>0){
  float hyp=sg_sqrt((float)dx*(float)dx+(float)dy*(float)dy);
  span=(int)((float)width*hyp/(float)major+0.5f);if(span<width)span=width;if(span>2*width)span=2*width;
 }
 int lo=(span-1)/2,hi=span/2;unsigned steps=0;
 for(;;){
  steps++;
  if(xmajor)vspan(c,x0,y0-lo,y0+hi,g);else sg_span(c,y0,x0-lo,x0+hi,g,false);
  if((x0==x1&&y0==y1)||steps>4096u)break;
  int e2=2*e;if(e2>=dy){e+=dy;x0+=sx;}if(e2<=dx){e+=dx;y0+=sy;}
 }
 return steps;
}
void sg_disc(const SGClip *c,int cx,int cy,int r,uint8_t g){
 if(r<0||r>64)return;
 for(int dy=-r;dy<=r;dy++){
  int w=(int)sg_sqrt((float)(r*r-dy*dy)+(float)r*0.8f);
  sg_span(c,cy+dy,cx-w,cx+w,g,false);
 }
}
void sg_ring(const SGClip *c,int cx,int cy,int r,int thick,uint8_t g){
 if(r<1||r>64||thick<1)return;
 if(thick>r)thick=r;
 float ro=(float)r+0.5f,ri=(float)(r-thick)+0.5f;
 for(int dy=-r;dy<=r;dy++){
  float d2=(float)(dy*dy);
  int outer=(int)sg_sqrt(ro*ro-d2);
  if(d2>=ri*ri){sg_span(c,cy+dy,cx-outer,cx+outer,g,false);continue;}
  int inner=(int)(sg_sqrt(ri*ri-d2)+0.999f);
  if(inner<=outer){sg_span(c,cy+dy,cx-outer,cx-inner,g,false);sg_span(c,cy+dy,cx+inner,cx+outer,g,false);}
 }
}
void sg_tri(const SGClip *c,float ax,float ay,float bx,float by,float cx,float cy,uint8_t g,bool set){
 if(!finite(ax)||!finite(ay)||!finite(bx)||!finite(by)||!finite(cx)||!finite(cy))return;
 float lo=ay<by?ay:by,hi=ay>by?ay:by;if(cy<lo)lo=cy;if(cy>hi)hi=cy;
 if(hi<(float)c->y0||lo>=(float)c->y1)return;
 int y0=clampi((int)(lo-1.0f),c->y0,c->y1-1),y1=clampi((int)(hi+1.0f),c->y0,c->y1-1);
 const float px[3]={ax,bx,cx},py[3]={ay,by,cy};
 for(int y=y0;y<=y1;y++){
  float yc=(float)y+0.5f,xl=SG_FLOAT_LIMIT,xr=-SG_FLOAT_LIMIT;
  for(unsigned i=0;i<3;i++){
   unsigned j=(i+1)%3;float ya=py[i],yb=py[j];
   if((ya<=yc&&yc<yb)||(yb<=yc&&yc<ya)){
    float x=px[i]+(px[j]-px[i])*(yc-ya)/(yb-ya);
    if(x<xl)xl=x;if(x>xr)xr=x;
   }
  }
  if(xl>xr)continue;
  if(xl<(float)c->x0-1.0f)xl=(float)c->x0-1.0f;
  if(xr>(float)c->x1)xr=(float)c->x1;
  int a=-flo(0.5f-xl),b=flo(xr-0.5f); /* pixel centres inside [xl,xr] */
  if(a<=b)sg_span(c,y,a,b,g,set);
 }
}
