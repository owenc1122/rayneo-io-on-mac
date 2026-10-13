#include "simulator.h"
#include <stdlib.h>
struct RNSimulator { SGRuntime runtime;SGAnim anim;bool open;uint8_t pixels[SG_W*SG_H]; };
static bool is_open(void *ctx){return ((RNSimulator *)ctx)->open;}
static enum SGResult open_view(void *ctx){((RNSimulator *)ctx)->open=true;return SG_OK;}
static void show(void *ctx){(void)ctx;}
static void close_view(void *ctx){((RNSimulator *)ctx)->open=false;}
RNSimulator *rn_create(void){return calloc(1,sizeof(RNSimulator));}
void rn_destroy(RNSimulator *s){free(s);}
int rn_receive(RNSimulator *s,const uint8_t *p,size_t n,uint32_t now){
 SGUI ui={s,is_open,open_view,show,close_view};bool send;
 return sg_receive(&s->runtime,&ui,p,n,now,&send).result;
}
void rn_orientation(RNSimulator *s,float yaw,uint32_t now){sg_anim_head_mode(&s->anim,true);sg_anim_head_sample(&s->anim,yaw,now,now);}
void rn_zoom(RNSimulator *s,int step,uint32_t now){sg_anim_zoom(&s->anim,step,now);}
void rn_reset(RNSimulator *s){sg_anim_reset(&s->anim);}
const SGScene *rn_scene(RNSimulator *s){return s->runtime.active?&s->runtime.scene:NULL;}
const uint8_t *rn_draw(RNSimulator *s,uint32_t now){
 const SGScene *scene=rn_scene(s);sg_anim_step(&s->anim,scene,s->runtime.generation,s->runtime.last_scene,now);
 sg_draw_panel(s->pixels,scene,false);sg_draw_map(s->pixels,scene,&s->anim,false,0,NULL);sg_anim_drawn(&s->anim);return s->pixels;
}
unsigned rn_labels(RNSimulator *s,SGFeatureLabel *out){return sg_feature_layout(rn_scene(s),&s->anim,0,out);}
float rn_mpp(RNSimulator *s){return s->anim.mpp;}
