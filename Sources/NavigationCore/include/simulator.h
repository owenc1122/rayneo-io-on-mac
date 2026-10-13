#ifndef RAYNEO_SIMULATOR_H
#define RAYNEO_SIMULATOR_H
#include "sgn_render.h"
typedef struct RNSimulator RNSimulator;
RNSimulator *rn_create(void);
void rn_destroy(RNSimulator *);
int rn_receive(RNSimulator *,const uint8_t *,size_t,uint32_t);
void rn_orientation(RNSimulator *,float,uint32_t);
void rn_zoom(RNSimulator *,int,uint32_t);
void rn_reset(RNSimulator *);
const uint8_t *rn_draw(RNSimulator *,uint32_t);
const SGScene *rn_scene(RNSimulator *);
unsigned rn_labels(RNSimulator *,SGFeatureLabel *);
float rn_mpp(RNSimulator *);
#endif
