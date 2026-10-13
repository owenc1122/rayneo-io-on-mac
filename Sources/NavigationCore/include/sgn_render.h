#ifndef SPARE_NAV_RENDER_H
#define SPARE_NAV_RENDER_H
/* Scene -> 512x128 L8 canvas. Pure functions over caller-owned buffers. */
#include "sgn_proto.h"
#include "sgn_raster.h"
#define SG_W 512
#define SG_H 128
#define SG_PANEL_W 150
#define SG_MAP_CX (SG_PANEL_W+(SG_W-SG_PANEL_W)/2)
#define SG_MAP_CY 96
#define SG_POINT_BUDGET 900u
#define SG_TAU_MS 300.0f       /* position + zoom smoothing */
#define SG_HEADING_TAU_MS 120.0f /* heading/rotation smoothing (real-time POSE) */
#define SG_HEAD_MAX_AGE_MS 350u
#define SG_ZOOM_STEP_MIN (-4)   /* local crown zoom: mpp x 1.25^step, 0.41x..3.8x (within 0.4..4) */
#define SG_ZOOM_STEP_MAX 6
#define SG_SCALE_SHOW_MS 1500u
#define SG_ICON_SIZE 44
typedef struct {
 float x,y,ox,oy,heading,rot,mpp;
 uint32_t last,generation,zoom_at;
 int8_t zoom_step; /* crown zoom, kept for the page session (reset only by sg_anim_reset) */
 bool init,zoomed,scale; /* scale: transient scale bar visible this frame */
 int32_t key[7];
 float head_heading;
 uint32_t head_at;
 bool head_mode,head_sample;
} SGAnim;
typedef struct { unsigned points,steps,roads,skipped; } SGDrawStats;
float sg_target_mpp(const SGScene *);
float sg_zoom_factor(int step); /* 1.25^step, clamped to [0.4,4] */
void sg_anim_reset(SGAnim *);
/* View orientation only. The sensor adapter must supply calibrated clockwise
 * true-north degrees, never raw gyro values or the phone compass. Enabling
 * without a sample keeps the last displayed orientation (north on a new page).
 * A stale sensor freezes the view; it never silently switches to the phone. */
void sg_anim_head_mode(SGAnim *,bool enabled);
bool sg_anim_head_sample(SGAnim *,float degrees,uint32_t sampled_at,uint32_t now);
bool sg_anim_head_fresh(const SGAnim *,uint32_t now);
/* Crown zoom: step>0 zooms in (fewer metres per pixel). Returns true when the
 * multiplier changed or the scale bar was (re)shown. */
bool sg_anim_zoom(SGAnim *,int step,uint32_t now);
/* Nice scale-bar length (metres) for mpp metres/pixel; *px receives its pixel length. */
uint32_t sg_scale_metres(float mpp,int *px);
/* Advance smoothing + dead reckoning. The map is always heading-up (vehicle
 * chevron points up). scene_rx = local tick when the scene/pose was
 * committed. Returns true when the visible frame differs from the last one
 * drawn (then the caller redraws and calls sg_anim_drawn). */
bool sg_anim_step(SGAnim *,const SGScene *,uint32_t generation,uint32_t scene_rx,uint32_t now);
void sg_anim_drawn(SGAnim *);
void sg_draw_icon(const SGClip *,int x,int y,unsigned icon,uint8_t gray);
/* Left panel art (icon + rules). scene may be NULL (no session). */
void sg_draw_panel(uint8_t *fb,const SGScene *,bool dim);
/* Right map. dim: waiting-for-phone. badge_w>0 reserves a dark badge box at the top-left of the map. */
void sg_draw_map(uint8_t *fb,const SGScene *,const SGAnim *,bool dim,int badge_w,SGDrawStats *);
#define SG_FEATURE_VISIBLE 8
/* Placement is shared by LVGL and the Mac preview. Text stays upright. */
typedef struct { int16_t x,y,w;uint8_t kind;char text[32]; } SGFeatureLabel;
unsigned sg_feature_layout(const SGScene *,const SGAnim *,int badge_w,SGFeatureLabel out[SG_FEATURE_VISIBLE]);
size_t sg_fmt_distance(char *,size_t,uint32_t metres);
size_t sg_fmt_bottom(char *,size_t,const SGScene *);
#endif
