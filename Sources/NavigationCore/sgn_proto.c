#include "sgn_proto.h"
#include <string.h>
static uint16_t u16(const uint8_t *p){return (uint16_t)(p[0]|((uint16_t)p[1]<<8));}
static uint32_t u32(const uint8_t *p){return p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static void p32(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
uint32_t sg_crc32(const uint8_t *p,size_t n){
 uint32_t c=~0u;
 for(size_t i=0;i<n;i++){c^=p[i];for(unsigned k=0;k<8;k++)c=(c>>1)^((0u-(c&1u))&0xedb88320u);}
 return ~c;
}
/* Strict UTF-8: no overlongs, surrogates or C0/DEL controls (labels render it verbatim). */
static bool utf8(const uint8_t *p,size_t n){
 for(size_t i=0;i<n;){
  uint32_t c=p[i++],min=0;unsigned left=0;
  if(c<0x80){if(c<32||c==127)return false;continue;}
  if(c>=0xc2&&c<=0xdf){c&=31;left=1;min=0x80;}
  else if(c>=0xe0&&c<=0xef){c&=15;left=2;min=0x800;}
  else if(c>=0xf0&&c<=0xf4){c&=7;left=3;min=0x10000;}
  else return false;
  if(n-i<left)return false;
  while(left--){uint8_t b=p[i++];if((b&0xc0)!=0x80)return false;c=(c<<6)|(b&63u);}
  if(c<min||c>0x10ffff||(c>=0xd800&&c<=0xdfff))return false;
 }
 return true;
}
bool sg_header(const uint8_t *p,size_t n,SGHeader *h){
 if(!p||n<SG_HEADER||n>SG_FILE_MAX||memcmp(p,"SGN1",4)||p[4]!=1||p[6]||p[7])return false;
 uint32_t sid=u32(p+8),seq=u32(p+12),len=u32(p+16),crc=u32(p+20);
 if(!sid||!seq||u32(p+24)||u32(p+28)||len!=n-SG_HEADER)return false;
 uint8_t op=p[5];
 if(op<SG_SCENE||op>SG_POSE)return false;
 if((op==SG_HEARTBEAT||op==SG_STOP)&&len)return false;
 if(op==SG_SCENE&&len<SG_SCENE_FIXED+4u)return false;
 if(op==SG_POSE&&len!=SG_POSE_LEN)return false;
 if(sg_crc32(p+SG_HEADER,len)!=crc)return false;
 if(h){h->sid=sid;h->seq=seq;h->length=len;h->crc=crc;h->op=op;}
 return true;
}
bool sg_scene_parse(const uint8_t *p,size_t n,SGScene *s){
 if(!p||n<SG_SCENE_FIXED+4u||n>SG_PAYLOAD_MAX)return false;
 uint16_t heading=u16(p+8);uint8_t icon=p[15],road=p[32],instr=p[33],eta=p[34];
 if(heading>35999u||icon>SG_ICON_MAX||road>SG_ROAD_NAME_MAX||instr>SG_INSTR_MAX||eta>SG_ETA_MAX||p[35]>1)return false;
 size_t at=SG_SCENE_FIXED,text=(size_t)road+instr+eta;
 if(n-at<text+2u)return false;
 if(!utf8(p+at,road)||!utf8(p+at+road,instr)||!utf8(p+at+road+instr,eta))return false;
 at+=text;
 size_t route_n=u16(p+at);at+=2;
 if(route_n>SG_ROUTE_MAX||(n-at)/4u<route_n)return false;
 size_t route_off=at;at+=route_n*4u;
 if(n-at<2u)return false;
 size_t roads=u16(p+at);at+=2;size_t roads_off=at,points=0;
 for(size_t i=0;i<roads;i++){
  if(n-at<2u)return false;
  uint8_t cls=p[at],count=p[at+1];at+=2;
  if(cls>3||count<SG_ROAD_PTS_MIN||count>SG_ROAD_PTS_MAX||(n-at)/4u<count)return false;
  at+=(size_t)count*4u;points+=count;
 }
 size_t features_off=at;uint8_t feature_count=0;
 if(p[35]==1){
  if(at==n)return false;
  feature_count=p[at++];features_off=at;
  if(feature_count>16)return false;
  for(unsigned i=0;i<feature_count;i++){
   if(n-at<6)return false;
   uint8_t kind=p[at],len=p[at+1];
   if(kind<1||kind>3||len>31||n-at-6<len||!utf8(p+at+6,len))return false;
   at+=6u+len;
  }
 }
 if(at!=n)return false; /* trailing garbage is a framing error, not padding */
 if(!s)return true;
 s->t_ms=u32(p);s->pos_x=sg_i16(p+4);s->pos_y=sg_i16(p+6);s->heading_cd=heading;
 s->speed_cms=u16(p+10);s->zoom_mpp_milli=u16(p+12);s->flags=p[14];s->icon=icon;
 s->man_dist_m=u32(p+16);s->remain_dist_m=u32(p+20);s->remain_time_s=u32(p+24);
 s->man_x=sg_i16(p+28);s->man_y=sg_i16(p+30);
 memcpy(s->road,p+SG_SCENE_FIXED,road);s->road[road]=0;
 memcpy(s->instr,p+SG_SCENE_FIXED+road,instr);s->instr[instr]=0;
 memcpy(s->eta,p+SG_SCENE_FIXED+road+instr,eta);s->eta[eta]=0;
 s->route_n=(uint16_t)route_n;s->route_off=(uint16_t)route_off;
 s->road_count=(uint16_t)roads;s->roads_off=(uint16_t)roads_off;s->road_points=(uint16_t)points;
 s->feature_count=feature_count;s->features_off=(uint16_t)features_off;
 s->length=(uint16_t)n;memcpy(s->raw,p,n);
 return true;
}
bool sg_pose_parse(const uint8_t *p,size_t n,SGScene *s){
 if(!p||n!=SG_POSE_LEN)return false;
 uint16_t heading=u16(p+8);if(heading>35999u)return false;
 if(s){s->t_ms=u32(p);s->pos_x=sg_i16(p+4);s->pos_y=sg_i16(p+6);s->heading_cd=heading;s->speed_cms=u16(p+10);}
 return true;
}
void sg_init(SGRuntime *r){if(r)memset(r,0,sizeof *r);}
enum SGState sg_state(const SGRuntime *r,bool open){
 if(open)return r->active?SG_NAVIGATING:SG_WAITING;
 if(r->exited_sid&&r->exited_sid==r->sid)return SG_EXITED;
 return SG_IDLE;
}
enum SGLink sg_link(const SGRuntime *r,uint32_t now){
 uint32_t idle=now-r->last_packet;
 return idle>=SG_WAIT_MS?SG_LINK_WAITING:idle>=SG_WEAK_MS?SG_LINK_WEAK:SG_LINK_FRESH;
}
bool sg_want_hold(const SGRuntime *r,bool open,uint32_t opened_at,uint32_t now){
 if(!open)return false;
 if(r->active)return (uint32_t)(now-r->last_packet)<SG_HOLD_MAX_MS;
 return (uint32_t)(now-opened_at)<SG_OPEN_HOLD_MS;
}
static void adopt(SGRuntime *r,const SGHeader *h){
 if(h->sid!=r->sid){r->prev_sid=r->sid;r->prev_seq=r->seq;r->sid=h->sid;r->active=false;}
 r->seq=h->seq;
}
static bool api(const SGUI *u){return u&&u->is_open&&u->open&&u->show&&u->close;}
SGReply sg_receive(SGRuntime *r,const SGUI *u,const uint8_t *p,size_t n,uint32_t now,bool *send){
 SGReply q={SG_BAD_PACKET,SG_IDLE,0,0,SG_EV_NONE};bool dummy;if(!send)send=&dummy;*send=true;
 /* Correlate with the request even when it is rejected. */
 if(p&&n>=16){q.sid=u32(p+8);q.seq=u32(p+12);}
 if(!r||!api(u))return q;
 bool open=u->is_open(u->ctx);q.state=(uint8_t)sg_state(r,open);
 SGHeader h;if(!sg_header(p,n,&h))return q;
 if((h.sid==r->sid&&h.seq<=r->seq)||(r->prev_sid&&h.sid==r->prev_sid&&h.seq<=r->prev_seq)){q.result=SG_STALE;return q;}
 q.result=SG_OK;
 if(h.op==SG_SCENE){
  if(!sg_scene_parse(p+SG_HEADER,h.length,NULL)){q.result=SG_BAD_PACKET;return q;}
  if(!open&&r->exited_sid&&h.sid==r->exited_sid){
   /* User left the page for this session: never auto-reopen it. */
   adopt(r,&h);q.state=SG_EXITED;return q;
  }
  if(!open){enum SGResult e=u->open(u->ctx);if(e!=SG_OK){q.result=(uint8_t)e;return q;}open=u->is_open(u->ctx);}
  adopt(r,&h);
  (void)sg_scene_parse(p+SG_HEADER,h.length,&r->scene);
  r->active=true;r->last_packet=r->last_scene=now;r->generation++;
  u->show(u->ctx);
 }else if(h.op==SG_POSE){
  /* Tiny real-time pose for the committed scene: no reply, no page open. */
  if(!sg_pose_parse(p+SG_HEADER,h.length,NULL)){q.result=SG_BAD_PACKET;return q;}
  if(h.sid==r->sid&&r->active){
   (void)sg_pose_parse(p+SG_HEADER,h.length,&r->scene);
   r->seq=h.seq;r->last_packet=r->last_scene=now;r->generation++;*send=false;
  }else if(!(r->exited_sid&&h.sid==r->exited_sid))q.event=SG_EV_NEED_SCENE; /* no scene yet: ignored, ask for one */
 }else if(h.op==SG_HEARTBEAT){
  if(h.sid==r->sid&&r->active){r->seq=h.seq;r->last_packet=now;*send=false;}
  else if(!(r->exited_sid&&h.sid==r->exited_sid))q.event=SG_EV_NEED_SCENE; /* unknown session: ask for a full scene */
 }else{
  if(h.sid==r->sid||!r->active){
   adopt(r,&h);r->active=false;
   if(open){u->close(u->ctx);open=u->is_open(u->ctx);}
  }
 }
 q.state=(uint8_t)sg_state(r,open);return q;
}
SGReply sg_user_open(SGRuntime *r,bool open){
 r->exited_sid=0;
 return (SGReply){SG_OK,(uint8_t)sg_state(r,open),r->sid,r->seq,SG_EV_OPENED};
}
SGReply sg_user_exit(SGRuntime *r){
 r->exited_sid=r->sid;r->active=false;
 return (SGReply){SG_OK,SG_EXITED,r->sid,r->seq,SG_EV_EXITED};
}
size_t sg_reply_encode(uint8_t *p,size_t cap,SGReply r){
 if(!p||cap<32)return 0;
 memset(p,0,32);memcpy(p,"SGR1",4);p[4]=1;p[5]=r.result;p[6]=r.state;
 p32(p+8,r.sid);p32(p+12,r.seq);p32(p+16,r.event);return 32;
}
