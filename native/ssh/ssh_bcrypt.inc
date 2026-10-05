// Own bcrypt_pbkdf implementation of the OpenBSD/OpenSSH algorithm.
// SHA-512 prehash, EksBlowfish, 64 state expansions and interleaved output.
#include "ssh_blowfish_constants.inc"
struct Blowfish {
  uint32_t p[18],s[1024];
  Blowfish(){std::memcpy(p,blowfish_initial,18*4);std::memcpy(s,blowfish_initial+18,1024*4);}
  uint32_t f(uint32_t x) const {return ((s[x>>24]+s[256+((x>>16)&255)])^s[512+((x>>8)&255)])+s[768+(x&255)];}
  void encrypt(uint32_t& left,uint32_t& right) const {
    uint32_t l=left,r=right;
    for(unsigned i=0;i<16;++i){l^=p[i];r^=f(l);uint32_t temp=l;l=r;r=temp;}
    uint32_t temp=l;l=r;r=temp;r^=p[16];l^=p[17];left=l;right=r;
  }
  static uint32_t next(const uint8_t* data,size_t size,size_t& position){uint32_t value=0;for(unsigned i=0;i<4;++i){value=(value<<8)|data[position];position=(position+1)%size;}return value;}
  void expand(const uint8_t* key,size_t key_size,const uint8_t* salt=nullptr,size_t salt_size=0) {
    size_t position=0;for(auto& word:p)word^=next(key,key_size,position);
    uint32_t left=0,right=0;position=0;
    for(unsigned i=0;i<18;i+=2){if(salt){left^=next(salt,salt_size,position);right^=next(salt,salt_size,position);}encrypt(left,right);p[i]=left;p[i+1]=right;}
    for(unsigned i=0;i<1024;i+=2){if(salt){left^=next(salt,salt_size,position);right^=next(salt,salt_size,position);}encrypt(left,right);s[i]=left;s[i+1]=right;}
  }
};
void bcrypt_hash(const uint8_t* password,const uint8_t* salt,uint8_t* result) {
  Blowfish state;state.expand(password,64,salt,64);
  for(unsigned i=0;i<64;++i){state.expand(salt,64);state.expand(password,64);}
  constexpr char magic[]="OxychromaticBlowfishSwatDynamite";uint32_t words[8];
  for(unsigned i=0;i<8;++i)words[i]=static_cast<uint32_t>(load_be(reinterpret_cast<const uint8_t*>(magic)+i*4,4));
  for(unsigned round=0;round<64;++round)for(unsigned i=0;i<8;i+=2)state.encrypt(words[i],words[i+1]);
  for(unsigned i=0;i<32;++i)result[i]=static_cast<uint8_t>(words[i/4]>>(8*(i%4)));
  wipe(&state,sizeof(state));wipe(words,sizeof(words));
}
bool bcrypt_derive(const uint8_t* password,size_t password_size,const uint8_t* salt,size_t salt_size,unsigned rounds,uint8_t* output,size_t output_size) {
  if(password_size==0||password_size>65536||salt_size==0||salt_size>64||rounds==0||rounds>128||output_size==0||output_size>64)return false;
  uint8_t pass_hash[64],salt_hash[64],counted_salt[68]{},previous[32],block[32];
  hash512(password,password_size,pass_hash);std::memcpy(counted_salt,salt,salt_size);
  size_t stride=(output_size+31)/32,amount=(output_size+stride-1)/stride;
  for(unsigned count=1;count<=stride;++count){
    store_be(counted_salt+salt_size,count,4);hash512(counted_salt,salt_size+4,salt_hash);bcrypt_hash(pass_hash,salt_hash,previous);std::memcpy(block,previous,32);
    for(unsigned iteration=1;iteration<rounds;++iteration){hash512(previous,32,salt_hash);bcrypt_hash(pass_hash,salt_hash,previous);for(unsigned i=0;i<32;++i)block[i]^=previous[i];}
    for(size_t i=0;i<amount;++i){size_t position=i*stride+count-1;if(position<output_size)output[position]=block[i];}
  }
  wipe(pass_hash,sizeof(pass_hash));wipe(salt_hash,sizeof(salt_hash));wipe(counted_salt,sizeof(counted_salt));wipe(previous,sizeof(previous));wipe(block,sizeof(block));return true;
}
