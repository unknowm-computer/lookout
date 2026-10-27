#include <assert.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static uid_t test_uid = 0;
static uid_t test_geteuid(void) { return test_uid; }
static int test_usleep(useconds_t delay);
static kern_return_t test_call(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
#define geteuid test_geteuid
#define usleep test_usleep
#define IOConnectCallStructMethod test_call
#include "../../Sources/CSMC/CSMC.c"
#undef IOConnectCallStructMethod
#undef geteuid
#undef usleep
static uint8_t modes[2] = {0,0};
static float targets[2] = {1800,1900};
static int delayed_writes = 0, pending_fan = -1, pending_ticks = 0;
static uint8_t pending_mode = 0;
static int test_usleep(useconds_t delay) {
    (void)delay;
    if (pending_fan >= 0 && --pending_ticks == 0) { modes[pending_fan] = pending_mode; pending_fan = -1; }
    return 0;
}
static uint8_t unlocked = 0;
static int writes = 0;
static int missing_unlock = 0, empty_write_reply = 0;
static kern_return_t test_call(mach_port_t connection, uint32_t selector, const void *input, size_t input_size, void *output, size_t *output_size) {
    (void)connection; assert(selector==2 && input_size==80 && *output_size==80);
    const Packet *in=input; Packet *out=output; memset(out,0,sizeof(*out));
    char key[5]={(char)(in->key>>24),(char)(in->key>>16),(char)(in->key>>8),(char)in->key,0};
    int fan=key[1]-'0'; int mode=(fan==0||fan==1)&&strcmp(key+2,"Md")==0;
    int target=(fan==0||fan==1)&&strcmp(key+2,"Tg")==0;
    int unlock=strcmp(key,"Ftst")==0;
    if (!mode && !target && !unlock) return kIOReturnNotFound;
    if (unlock && missing_unlock) { out->result=0x84; return 0; }
    if(in->command==9){out->info.size=target?4:1;out->info.type=fourcc(target?"flt ":"ui8 ");}
    else if(in->command==5){if(target)memcpy(out->bytes,&targets[fan],4);else out->bytes[0]=mode?modes[fan]:unlocked;}
    else if(in->command==6){
        writes++;if(empty_write_reply)*output_size=0;
        if(target)memcpy(&targets[fan],in->bytes,4);
        else if(mode) {
            if(delayed_writes) { pending_fan=fan; pending_mode=in->bytes[0]; pending_ticks=3; }
            else modes[fan]=in->bytes[0];
        } else unlocked=in->bytes[0];
    }
    else assert(0);
    return 0;
}
int main(void) {
    assert(lookout_smc_fan_target(1,0,2500)==0 && modes[0]==1 && targets[0]==2500);
    assert(lookout_smc_fan_target(1,1,2800)==0 && modes[1]==1 && targets[1]==2800);
    int previous=writes;
    assert(lookout_smc_fan_target(1,2,2800)!=0);
    assert(lookout_smc_fan_target(1,0,NAN)!=0);
    assert(lookout_smc_fan_target(1,0,-1)!=0);
    assert(lookout_smc_fan_target(1,0,15000)!=0);
    assert(writes==previous);
    test_uid=501;
    assert(lookout_smc_fan_target(1,0,2600)!=0 && writes==previous);
    test_uid=0;
    assert(lookout_smc_fan_auto(1,0)==0 && modes[0]==0 && targets[0]==0);
    assert(lookout_smc_fan_auto(1,1)==0 && modes[1]==0 && targets[1]==0);
    // Some firmware acknowledges writes with no output packet.
    empty_write_reply=1;
    assert(lookout_smc_fan_target(1,0,2600)==0 && modes[0]==1 && targets[0]==2600);
    assert(lookout_smc_fan_auto(1,0)==0 && modes[0]==0);
    // This M1 Pro has no Ftst key; restoring automatic mode must still succeed.
    missing_unlock=1;
    assert(lookout_smc_fan_target(1,1,3000)==0 && modes[1]==1);
    assert(lookout_smc_fan_auto(1,1)==0 && modes[1]==0);
    // The driver can acknowledge a mode write before subsequent reads reflect it.
    delayed_writes=1;
    assert(lookout_smc_fan_target(1,0,3100)==0 && modes[0]==1);
    assert(lookout_smc_fan_auto(1,0)==0 && modes[0]==0 && pending_fan==-1);
    // A delayed manual write must be cancelled even while the current read is automatic.
    modes[0]=0;pending_fan=0;pending_mode=1;pending_ticks=2;
    assert(lookout_smc_fan_auto(1,0)==0 && modes[0]==0 && pending_fan==-1);
    puts("SMC ABI, bounded write API, root-only writes, both-fan restore and absent optional keys passed");
}
