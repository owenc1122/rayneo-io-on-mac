#ifndef SPARE_NAV_PROTO_H
#define SPARE_NAV_PROTO_H
/* SGN1 vector navigation (docs/PROTOCOL.md). Pure C, no native calls: the
 * glue in nav_service.c owns LVGL/power. UI executor only after paired()
 * validation. All parsing is bounds-checked against the received length. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define SG_FILE_MAX 4096u
#define SG_HEADER 32u
#define SG_PAYLOAD_MAX (SG_FILE_MAX-SG_HEADER)
#define SG_SCENE_FIXED 36u
#define SG_POSE_LEN 12u /* u32 t_ms, i16 pos_x, i16 pos_y, u16 heading_cd, u16 speed_cms */
#define SG_ROUTE_MAX 256u
#define SG_ROAD_PTS_MIN 2u
#define SG_ROAD_PTS_MAX 64u
#define SG_ROAD_NAME_MAX 63u
#define SG_INSTR_MAX 47u
#define SG_ETA_MAX 7u
#define SG_ICON_MAX 12u
#define SG_WEAK_MS 30000u    /* no packet -> 信号弱 badge */
#define SG_WAIT_MS 120000u   /* no packet -> 等待手机 state, page stays */
#define SG_HOLD_MAX_MS 600000u /* nav-agent change: no packet for 10 min -> release token, page stays */
#define SG_OPEN_HOLD_MS 120000u /* user-opened page without session keeps screen on this long */
#define SG_DR_MAX_MS 3000u
enum SGOp { SG_SCENE=1,SG_HEARTBEAT=2,SG_STOP=3,SG_POSE=4 };
enum SGResult { SG_OK=0,SG_BAD_PACKET=1,SG_BUSY=2,SG_STALE=3,SG_UI_FAILED=4 };
enum SGState { SG_IDLE=0,SG_WAITING=1,SG_NAVIGATING=2,SG_EXITED=3 };
enum SGEvent { SG_EV_NONE=0,SG_EV_OPENED=1,SG_EV_EXITED=2,SG_EV_NEED_SCENE=3 };
enum SGFlag { SG_F_REROUTE=1,SG_F_GPS_WEAK=2,SG_F_ARRIVED=4,SG_F_WALK=8,SG_F_NORTH_UP=16 /* ignored: the map is always heading-up */ };
enum SGLink { SG_LINK_FRESH=0,SG_LINK_WEAK=1,SG_LINK_WAITING=2 };
typedef struct { uint32_t sid,seq,length,crc;uint8_t op; } SGHeader;
/* Validated scene. Point arrays stay in the copied payload (raw) and are read
 * through the offsets below; text is NUL-terminated copies. */
typedef struct {
 uint32_t t_ms,man_dist_m,remain_dist_m,remain_time_s;
 int16_t pos_x,pos_y,man_x,man_y;
 uint16_t heading_cd,speed_cms,zoom_mpp_milli;
 uint8_t flags,icon;
 char road[SG_ROAD_NAME_MAX+1],instr[SG_INSTR_MAX+1],eta[SG_ETA_MAX+1];
 uint16_t route_n,route_off,road_count,roads_off,road_points,length;
 uint16_t features_off;
 uint8_t feature_count;
 uint8_t raw[SG_PAYLOAD_MAX];
} SGScene;
typedef struct { uint8_t result,state;uint32_t sid,seq,event; } SGReply;
typedef struct {
 SGScene scene;
 uint32_t sid,seq,prev_sid,prev_seq,exited_sid,generation;
 uint32_t last_packet,last_scene;
 bool active; /* a SCENE was committed for sid and neither STOP nor user exit followed */
} SGRuntime;
/* Glue supplied by the native page owner; mocked by host tests. */
typedef struct {
 void *ctx;
 bool (*is_open)(void *);
 enum SGResult (*open)(void *); /* page open for an incoming scene: OK, BUSY or UI_FAILED */
 void (*show)(void *);          /* scene committed; renderer redraws on its own timer */
 void (*close)(void *);         /* STOP: close page and release screen token */
} SGUI;
uint32_t sg_crc32(const uint8_t *,size_t);
bool sg_header(const uint8_t *,size_t,SGHeader *); /* framing + CRC + op/payload size */
bool sg_scene_parse(const uint8_t *payload,size_t n,SGScene *out); /* out may be NULL: validate only */
/* POSE: exactly SG_POSE_LEN bytes, heading<=35999. Updates only t/pos/heading/speed of out (may be NULL). */
bool sg_pose_parse(const uint8_t *payload,size_t n,SGScene *out);
void sg_init(SGRuntime *);
/* Returns the reply; *send=false means the protocol wants no reply (valid heartbeat). */
SGReply sg_receive(SGRuntime *,const SGUI *,const uint8_t *,size_t,uint32_t now,bool *send);
SGReply sg_user_open(SGRuntime *,bool page_open);
SGReply sg_user_exit(SGRuntime *);
enum SGState sg_state(const SGRuntime *,bool page_open);
enum SGLink sg_link(const SGRuntime *,uint32_t now);
/* Always-on screen policy (fold handled by caller). opened_at = page open tick. */
bool sg_want_hold(const SGRuntime *,bool page_open,uint32_t opened_at,uint32_t now);
size_t sg_reply_encode(uint8_t *,size_t,SGReply);
static inline int16_t sg_i16(const uint8_t *p){return (int16_t)(uint16_t)(p[0]|((uint16_t)p[1]<<8));}
#endif
