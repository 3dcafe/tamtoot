// TamToot's portable SSH primitives. No external cryptographic library.
// Algorithms: RFC 7748, FIPS 180-4, FIPS 197 / SP 800-38A.
// Fixed-operation X25519 ladder and AES S-box arithmetic; not independently audited.
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#define SSH_EXPORT extern "C" __declspec(dllexport)
#else
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#define SSH_EXPORT extern "C" __attribute__((visibility("default"), used))
#endif

namespace {
constexpr size_t limit = 2 * 1024 * 1024;
void wipe(void* memory, size_t size) {
  auto p = static_cast<volatile uint8_t*>(memory);
  while (size--) *p++ = 0;
}
bool random_bytes(uint8_t* out, size_t n) {
#if defined(_WIN32)
  return BCryptGenRandom(nullptr, out, static_cast<ULONG>(n), BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#elif defined(__APPLE__)
  arc4random_buf(out, n);
  return true;
#else
  size_t offset = 0;
#if defined(SYS_getrandom)
  while (offset < n) {
    const auto count = syscall(SYS_getrandom, out + offset, n - offset, 0);
    if (count > 0) offset += static_cast<size_t>(count);
    else if (count < 0 && errno == EINTR) continue;
    else if (count < 0 && errno == ENOSYS) break;
    else return false;
  }
  if (offset == n) return true;
#endif
  const int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  while (offset < n) {
    const auto count = read(fd, out + offset, n - offset);
    if (count > 0) offset += static_cast<size_t>(count);
    else if (count < 0 && errno == EINTR) continue;
    else { close(fd); return false; }
  }
  close(fd);
  return true;
#endif
}
uint32_t rotr32(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }
uint64_t rotr64(uint64_t x, unsigned n) { return (x >> n) | (x << (64 - n)); }
uint64_t load_be(const uint8_t* p, unsigned n) {
  uint64_t x = 0;
  for (unsigned i = 0; i < n; ++i) x = (x << 8) | p[i];
  return x;
}
void store_be(uint8_t* p, uint64_t x, unsigned n) {
  for (unsigned i = 0; i < n; ++i) { p[n - 1 - i] = static_cast<uint8_t>(x); x >>= 8; }
}
constexpr uint32_t k256[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
constexpr uint64_t k512[80] = {
  0x428a2f98d728ae22ULL,0x7137449123ef65cdULL,0xb5c0fbcfec4d3b2fULL,0xe9b5dba58189dbbcULL,
  0x3956c25bf348b538ULL,0x59f111f1b605d019ULL,0x923f82a4af194f9bULL,0xab1c5ed5da6d8118ULL,
  0xd807aa98a3030242ULL,0x12835b0145706fbeULL,0x243185be4ee4b28cULL,0x550c7dc3d5ffb4e2ULL,
  0x72be5d74f27b896fULL,0x80deb1fe3b1696b1ULL,0x9bdc06a725c71235ULL,0xc19bf174cf692694ULL,
  0xe49b69c19ef14ad2ULL,0xefbe4786384f25e3ULL,0x0fc19dc68b8cd5b5ULL,0x240ca1cc77ac9c65ULL,
  0x2de92c6f592b0275ULL,0x4a7484aa6ea6e483ULL,0x5cb0a9dcbd41fbd4ULL,0x76f988da831153b5ULL,
  0x983e5152ee66dfabULL,0xa831c66d2db43210ULL,0xb00327c898fb213fULL,0xbf597fc7beef0ee4ULL,
  0xc6e00bf33da88fc2ULL,0xd5a79147930aa725ULL,0x06ca6351e003826fULL,0x142929670a0e6e70ULL,
  0x27b70a8546d22ffcULL,0x2e1b21385c26c926ULL,0x4d2c6dfc5ac42aedULL,0x53380d139d95b3dfULL,
  0x650a73548baf63deULL,0x766a0abb3c77b2a8ULL,0x81c2c92e47edaee6ULL,0x92722c851482353bULL,
  0xa2bfe8a14cf10364ULL,0xa81a664bbc423001ULL,0xc24b8b70d0f89791ULL,0xc76c51a30654be30ULL,
  0xd192e819d6ef5218ULL,0xd69906245565a910ULL,0xf40e35855771202aULL,0x106aa07032bbd1b8ULL,
  0x19a4c116b8d2d0c8ULL,0x1e376c085141ab53ULL,0x2748774cdf8eeb99ULL,0x34b0bcb5e19b48a8ULL,
  0x391c0cb3c5c95a63ULL,0x4ed8aa4ae3418acbULL,0x5b9cca4f7763e373ULL,0x682e6ff3d6b2b8a3ULL,
  0x748f82ee5defb2fcULL,0x78a5636f43172f60ULL,0x84c87814a1f0ab72ULL,0x8cc702081a6439ecULL,
  0x90befffa23631e28ULL,0xa4506cebde82bde9ULL,0xbef9a3f7b2c67915ULL,0xc67178f2e372532bULL,
  0xca273eceea26619cULL,0xd186b8c721c0c207ULL,0xeada7dd6cde0eb1eULL,0xf57d4f7fee6ed178ULL,
  0x06f067aa72176fbaULL,0x0a637dc5a2c898a6ULL,0x113f9804bef90daeULL,0x1b710b35131c471bULL,
  0x28db77f523047d84ULL,0x32caab7b40c72493ULL,0x3c9ebe0a15c9bebcULL,0x431d67c49c100d4cULL,
  0x4cc5d4becb3e42b6ULL,0x597f299cfc657e2aULL,0x5fcb6fab3ad6faecULL,0x6c44198c4a475817ULL};
void block256(uint32_t* h, const uint8_t* input) {
  uint32_t w[64];
  for (unsigned i=0;i<16;++i) w[i]=static_cast<uint32_t>(load_be(input+4*i,4));
  for (unsigned i=16;i<64;++i) {
    auto x=w[i-15], y=w[i-2];
    w[i]=w[i-16]+(rotr32(x,7)^rotr32(x,18)^(x>>3))+w[i-7]+(rotr32(y,17)^rotr32(y,19)^(y>>10));
  }
  uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],j=h[7];
  for(unsigned i=0;i<64;++i) {
    auto t1=j+(rotr32(e,6)^rotr32(e,11)^rotr32(e,25))+((e&f)^(~e&g))+k256[i]+w[i];
    auto t2=(rotr32(a,2)^rotr32(a,13)^rotr32(a,22))+((a&b)^(a&c)^(b&c));
    j=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
  }
  h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=j;
  wipe(w,sizeof(w));
}
void block512(uint64_t* h, const uint8_t* input) {
  uint64_t w[80];
  for(unsigned i=0;i<16;++i) w[i]=load_be(input+8*i,8);
  for(unsigned i=16;i<80;++i) {
    auto x=w[i-15],y=w[i-2];
    w[i]=w[i-16]+(rotr64(x,1)^rotr64(x,8)^(x>>7))+w[i-7]+(rotr64(y,19)^rotr64(y,61)^(y>>6));
  }
  uint64_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],j=h[7];
  for(unsigned i=0;i<80;++i) {
    auto t1=j+(rotr64(e,14)^rotr64(e,18)^rotr64(e,41))+((e&f)^(~e&g))+k512[i]+w[i];
    auto t2=(rotr64(a,28)^rotr64(a,34)^rotr64(a,39))+((a&b)^(a&c)^(b&c));
    j=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
  }
  h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=j;
  wipe(w,sizeof(w));
}
void hash256(const uint8_t* data,size_t length,uint8_t* out) {
  uint32_t h[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  size_t full=length/64;
  for(size_t i=0;i<full;++i) block256(h,data+64*i);
  uint8_t tail[128]={};size_t rem=length%64;
  if(rem) std::memcpy(tail,data+64*full,rem);
  tail[rem]=128;size_t n=rem<56?64:128;
  store_be(tail+n-8,static_cast<uint64_t>(length)*8,8);
  block256(h,tail);if(n==128) block256(h,tail+64);
  for(unsigned i=0;i<8;++i) store_be(out+4*i,h[i],4);
  wipe(h,sizeof(h));wipe(tail,sizeof(tail));
}
void hash512(const uint8_t* data,size_t length,uint8_t* out) {
  uint64_t h[8]={0x6a09e667f3bcc908ULL,0xbb67ae8584caa73bULL,0x3c6ef372fe94f82bULL,0xa54ff53a5f1d36f1ULL,
    0x510e527fade682d1ULL,0x9b05688c2b3e6c1fULL,0x1f83d9abfb41bd6bULL,0x5be0cd19137e2179ULL};
  size_t full=length/128;
  for(size_t i=0;i<full;++i) block512(h,data+128*i);
  uint8_t tail[256]={};size_t rem=length%128;
  if(rem) std::memcpy(tail,data+128*full,rem);
  tail[rem]=128;size_t n=rem<112?128:256;
  store_be(tail+n-8,static_cast<uint64_t>(length)*8,8);
  block512(h,tail);if(n==256) block512(h,tail+128);
  for(unsigned i=0;i<8;++i) store_be(out+8*i,h[i],8);
  wipe(h,sizeof(h));wipe(tail,sizeof(tail));
}
using Field=int64_t[16];
void carry(Field a) {
  for(unsigned i=0;i<16;++i) {
    a[i]+=65536;const auto q=a[i]>>16;a[i]-=q*65536;
    if(i<15) a[i+1]+=q-1;else a[0]+=38*(q-1);
  }
}
void swap(Field a,Field b,int64_t bit) {
  const auto mask=-bit;
  for(unsigned i=0;i<16;++i) {auto x=mask&(a[i]^b[i]);a[i]^=x;b[i]^=x;}
}
void add(Field out,const Field a,const Field b) {for(unsigned i=0;i<16;++i) out[i]=a[i]+b[i];}
void sub(Field out,const Field a,const Field b) {for(unsigned i=0;i<16;++i) out[i]=a[i]-b[i];}
void mul(Field out,const Field a,const Field b) {
  int64_t t[31]={};
  for(unsigned i=0;i<16;++i) for(unsigned j=0;j<16;++j) t[i+j]+=a[i]*b[j];
  for(unsigned i=0;i<15;++i) t[i]+=38*t[i+16];
  for(unsigned i=0;i<16;++i) out[i]=t[i];
  carry(out);carry(out);wipe(t,sizeof(t));
}
void inverse(Field out,const Field input) {
  Field a;std::memcpy(a,input,sizeof(a));
  for(int i=253;i>=0;--i) {mul(a,a,a);if(i!=2&&i!=4) mul(a,a,input);}
  std::memcpy(out,a,sizeof(a));wipe(a,sizeof(a));
}
void pack(uint8_t* out,const Field input) {
  Field t,m;std::memcpy(t,input,sizeof(t));carry(t);carry(t);carry(t);
  for(unsigned iteration=0;iteration<2;++iteration) {
    m[0]=t[0]-65517;
    for(unsigned i=1;i<15;++i) {m[i]=t[i]-65535-((m[i-1]>>16)&1);m[i-1]&=65535;}
    m[15]=t[15]-32767-((m[14]>>16)&1);const auto borrow=(m[15]>>16)&1;m[14]&=65535;
    swap(t,m,1-borrow);
  }
  for(unsigned i=0;i<16;++i) {out[2*i]=static_cast<uint8_t>(t[i]);out[2*i+1]=static_cast<uint8_t>(t[i]>>8);}
  wipe(t,sizeof(t));wipe(m,sizeof(m));
}
void x25519(const uint8_t* scalar,const uint8_t* peer,uint8_t* out) {
  struct Work {Field x1,x2,z2,x3,z3,a,aa,b,bb,e,c,d,da,cb,t,u,factor;} w{};
  uint8_t n[32];std::memcpy(n,scalar,32);n[0]&=248;n[31]=(n[31]&127)|64;
  for(unsigned i=0;i<16;++i) w.x1[i]=peer[2*i]+(static_cast<int64_t>(peer[2*i+1])<<8);
  w.x1[15]&=32767;w.x2[0]=1;w.z3[0]=1;w.factor[0]=121665;std::memcpy(w.x3,w.x1,sizeof(Field));
  int64_t previous=0;
  for(int bit=254;bit>=0;--bit) {
    int64_t k=(n[bit/8]>>(bit&7))&1;
    swap(w.x2,w.x3,previous^k);swap(w.z2,w.z3,previous^k);previous=k;
    add(w.a,w.x2,w.z2);mul(w.aa,w.a,w.a);sub(w.b,w.x2,w.z2);mul(w.bb,w.b,w.b);sub(w.e,w.aa,w.bb);
    add(w.c,w.x3,w.z3);sub(w.d,w.x3,w.z3);mul(w.da,w.d,w.a);mul(w.cb,w.c,w.b);
    add(w.t,w.da,w.cb);mul(w.x3,w.t,w.t);sub(w.t,w.da,w.cb);mul(w.u,w.t,w.t);mul(w.z3,w.x1,w.u);
    mul(w.x2,w.aa,w.bb);mul(w.t,w.factor,w.e);add(w.t,w.aa,w.t);mul(w.z2,w.e,w.t);
  }
  swap(w.x2,w.x3,previous);swap(w.z2,w.z3,previous);inverse(w.t,w.z2);mul(w.u,w.x2,w.t);pack(out,w.u);
  wipe(n,sizeof(n));wipe(&w,sizeof(w));
}
uint8_t gf_mul(uint8_t a,uint8_t b) {
  uint8_t result=0;
  for(unsigned i=0;i<8;++i) {result^=static_cast<uint8_t>(-(b&1))&a;a=static_cast<uint8_t>((a<<1)^((-(a>>7))&0x1b));b>>=1;}
  return result;
}
uint8_t sbox(uint8_t value) {
  uint8_t x=1;
  for(int i=7;i>=0;--i) {x=gf_mul(x,x);if((254>>i)&1) x=gf_mul(x,value);}
  uint8_t y=x;
  for(unsigned i=1;i<=4;++i) y^=static_cast<uint8_t>((x<<i)|(x>>(8-i)));
  return y^0x63;
}
struct Cipher {
  uint8_t keys[240],counter[16],stream[16];unsigned offset=16;
  Cipher(const uint8_t* key,const uint8_t* iv) {
    std::memcpy(keys,key,32);std::memcpy(counter,iv,16);uint8_t rcon=1;
    for(unsigned pos=32;pos<240;pos+=4) {
      uint8_t t[4];std::memcpy(t,keys+pos-4,4);
      if(pos%32==0) {auto first=t[0];t[0]=sbox(t[1])^rcon;t[1]=sbox(t[2]);t[2]=sbox(t[3]);t[3]=sbox(first);rcon=gf_mul(rcon,2);}
      else if(pos%32==16) for(auto& x:t) x=sbox(x);
      for(unsigned i=0;i<4;++i) keys[pos+i]=keys[pos+i-32]^t[i];
      wipe(t,sizeof(t));
    }
  }
  void block() {
    uint8_t s[16],t[16];for(unsigned i=0;i<16;++i) s[i]=counter[i]^keys[i];
    for(unsigned round=1;round<=14;++round) {
      for(unsigned i=0;i<16;++i) t[i]=sbox(s[(i+4*(i%4))%16]);
      if(round<14) for(unsigned col=0;col<4;++col) {
        auto p=t+4*col;uint8_t a=p[0],b=p[1],c=p[2],d=p[3];
        p[0]=gf_mul(a,2)^gf_mul(b,3)^c^d;p[1]=a^gf_mul(b,2)^gf_mul(c,3)^d;
        p[2]=a^b^gf_mul(c,2)^gf_mul(d,3);p[3]=gf_mul(a,3)^b^c^gf_mul(d,2);
      }
      for(unsigned i=0;i<16;++i) s[i]=t[i]^keys[16*round+i];
    }
    std::memcpy(stream,s,16);unsigned c=1;
    for(int i=15;i>=0;--i) {unsigned v=counter[i]+c;counter[i]=static_cast<uint8_t>(v);c=v>>8;}
    offset=0;wipe(s,sizeof(s));wipe(t,sizeof(t));
  }
  void apply(const uint8_t* input,size_t size,uint8_t* output) {
    for(size_t i=0;i<size;++i) {if(offset==16) block();output[i]=input[i]^stream[offset++];}
  }
};
struct Exchange {uint8_t scalar[32];};
#include "ssh_auth_crypto.inc"
#include "ssh_bcrypt.inc"
}
SSH_EXPORT void* tamtoot_ssh_alloc(size_t n) {return n>0&&n<=limit?std::calloc(1,n):nullptr;}
SSH_EXPORT void tamtoot_ssh_free(void* p,size_t n) {if(p) {wipe(p,n);std::free(p);}}
SSH_EXPORT int tamtoot_ssh_random(uint8_t* out,size_t n) {return out&&n<=limit&&random_bytes(out,n)?1:0;}
SSH_EXPORT int tamtoot_ssh_hash(int bits,const uint8_t* input,size_t n,uint8_t* out) {
  if(!input||!out||n>limit) return 0;
  if(bits==256) hash256(input,n,out);else if(bits==512) hash512(input,n,out);else return 0;
  return 1;
}
SSH_EXPORT int tamtoot_ssh_x25519(const uint8_t* scalar,const uint8_t* peer,uint8_t* out) {
  if(!scalar||!peer||!out) return 0;x25519(scalar,peer,out);uint8_t nonzero=0;for(unsigned i=0;i<32;++i) nonzero|=out[i];return nonzero?1:0;
}
SSH_EXPORT void* tamtoot_ssh_exchange_create(uint8_t* public_key) {
  if(!public_key) return nullptr;
  auto p=new(std::nothrow) Exchange{};if(!p) return nullptr;
  if(!random_bytes(p->scalar,32)) {wipe(p,sizeof(*p));delete p;return nullptr;}
  uint8_t base[32]={9};x25519(p->scalar,base,public_key);return p;
}
SSH_EXPORT int tamtoot_ssh_exchange_shared(void* handle,const uint8_t* peer,uint8_t* out) {
  if(!handle) return 0;return tamtoot_ssh_x25519(static_cast<Exchange*>(handle)->scalar,peer,out);
}
SSH_EXPORT void tamtoot_ssh_exchange_free(void* handle) {if(handle) {auto p=static_cast<Exchange*>(handle);wipe(p,sizeof(*p));delete p;}}
SSH_EXPORT void* tamtoot_ssh_cipher_create(const uint8_t* key,const uint8_t* iv) {return key&&iv?new(std::nothrow) Cipher(key,iv):nullptr;}
SSH_EXPORT int tamtoot_ssh_cipher_apply(void* handle,const uint8_t* data,size_t n,uint8_t* out) {
  if(!handle||!data||!out||n>limit) return 0;static_cast<Cipher*>(handle)->apply(data,n,out);return 1;
}
SSH_EXPORT void tamtoot_ssh_cipher_free(void* handle) {if(handle) {auto p=static_cast<Cipher*>(handle);wipe(p,sizeof(*p));delete p;}}

SSH_EXPORT void* tamtoot_ssh_signer_create(int kind,const uint8_t* material,size_t length) {
  if(!material||length>65536||(kind!=1&&kind!=2))return nullptr;
  auto key=new(std::nothrow) SigningKey{};if(!key)return nullptr;key->kind=kind;bool valid=false;
  if(kind==1&&length==64){
    std::memcpy(key->seed,material,32);uint8_t scalar[64];hash512(key->seed,32,scalar);scalar[0]&=248;scalar[31]=(scalar[31]&63)|64;
    ed_multiply(key->public_key,scalar);wipe(scalar,sizeof(scalar));valid=equal_bytes(key->public_key,material+32,32);key->size=64;
  }else if(kind==2)valid=rsa_initialize(*key,material,length);
  if(!valid){wipe(key,sizeof(*key));delete key;return nullptr;}return key;
}
SSH_EXPORT size_t tamtoot_ssh_signer_size(void* handle){return handle?static_cast<SigningKey*>(handle)->size:0;}
SSH_EXPORT int tamtoot_ssh_signer_sign(void* handle,int bits,const uint8_t* message,size_t length,uint8_t* out,size_t out_length){
  if(!handle||!message||!out||length>1024*1024)return 0;const auto& key=*static_cast<SigningKey*>(handle);
  if(out_length!=key.size)return 0;return (key.kind==1&&bits==0?ed_sign(key,message,length,out):key.kind==2?rsa_sign(key,bits,message,length,out):false)?1:0;
}
SSH_EXPORT void tamtoot_ssh_signer_free(void* handle){if(handle){auto key=static_cast<SigningKey*>(handle);wipe(key,sizeof(*key));delete key;}}

SSH_EXPORT int tamtoot_ssh_bcrypt(const uint8_t* password,size_t password_size,const uint8_t* salt,size_t salt_size,unsigned rounds,uint8_t* output,size_t output_size){
  if(!password||!salt||!output)return 0;return bcrypt_derive(password,password_size,salt,salt_size,rounds,output,output_size)?1:0;
}
