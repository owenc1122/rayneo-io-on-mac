#ifndef SPARE_NAV_RASTER_H
#define SPARE_NAV_RASTER_H
/* Tiny L8 rasterizer. Every write is checked against the clip rectangle,
 * which callers keep inside the pixel buffer: no input (NaN, inf, ±1e30,
 * negative width) can write outside it. No libm, no heap, no globals. */
#include <stdbool.h>
#include <stdint.h>
typedef struct { uint8_t *px; int stride,x0,y0,x1,y1; } SGClip; /* [x0,x1) x [y0,y1) */
float sg_sin(float deg);
float sg_cos(float deg);
float sg_sqrt(float);
float sg_exp_neg(float x); /* e^-x for x>=0 */
float sg_wrap360(float deg);
float sg_wrap180(float deg); /* (-180,180] */
void sg_fill(const SGClip *,uint8_t);
void sg_box(const SGClip *,int x,int y,int w,int h,uint8_t g);   /* filled, overwrite */
void sg_frame(const SGClip *,int x,int y,int w,int h,uint8_t g); /* 1px outline, overwrite */
void sg_span(const SGClip *,int y,int xa,int xb,uint8_t g,bool set);
/* Thick line, Cohen-Sutherland clipped, max-blend. Returns Bresenham steps. */
unsigned sg_line(const SGClip *,float ax,float ay,float bx,float by,int width,uint8_t g);
void sg_disc(const SGClip *,int cx,int cy,int r,uint8_t g);
void sg_ring(const SGClip *,int cx,int cy,int r,int thick,uint8_t g);
void sg_tri(const SGClip *,float ax,float ay,float bx,float by,float cx,float cy,uint8_t g,bool set);
#endif
