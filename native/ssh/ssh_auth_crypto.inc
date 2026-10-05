// Own fixed-operation Ed25519 signing and RSA PKCS#1 v1.5 SHA-2 signing.
// Included inside ssh_crypto.cpp's private namespace; no third-party library.
constexpr int64_t ed_base_x[16] = {54554,36645,11616,51542,42930,38181,51040,26924,56412,64982,57905,49316,21502,52590,14035,8553};
constexpr int64_t ed_base_y[16] = {26200,26214,26214,26214,26214,26214,26214,26214,26214,26214,26214,26214,26214,26214,26214,26214};
constexpr int64_t ed_d2[16] = {61785,9906,39828,60374,45398,33411,5274,224,53552,61171,33010,6542,64743,22239,55772,9222};
constexpr uint32_t ed_order[8] = {0x5cf5d3ed,0x5812631a,0xa2f79cd6,0x14def9de,0,0,0,0x10000000};
constexpr unsigned rsa_max_words = 128; // 4096-bit maximum, bounded native CPU/memory.

// Shift a reduced unsigned integer by one bit and reduce again. Fixed word count.
void shift_mod(uint32_t* value, const uint32_t* modulus, unsigned words, unsigned bit) {
  uint32_t difference[rsa_max_words]; uint64_t carry_bit=bit;
  for(unsigned i=0;i<words;++i) {
    uint64_t v=(static_cast<uint64_t>(value[i])<<1)|carry_bit;
    value[i]=static_cast<uint32_t>(v);carry_bit=v>>32;
  }
  uint64_t borrow=0;
  for(unsigned i=0;i<words;++i) {
    uint64_t v=static_cast<uint64_t>(value[i])-modulus[i]-borrow;
    difference[i]=static_cast<uint32_t>(v);borrow=v>>63;
  }
  uint32_t mask=0-static_cast<uint32_t>(1-((carry_bit-borrow)>>63));
  for(unsigned i=0;i<words;++i) value[i]=(difference[i]&mask)|(value[i]&~mask);
  wipe(difference,sizeof(difference));
}
void reduce_bytes(const uint8_t* bytes, size_t length, const uint32_t* modulus, unsigned words, uint32_t* result) {
  std::memset(result,0,words*4);
  for(size_t index=length;index>0;--index)
    for(int bit=7;bit>=0;--bit) shift_mod(result,modulus,words,(bytes[index-1]>>bit)&1);
}
void words_bytes(const uint32_t* words, unsigned count, uint8_t* bytes) {
  for(unsigned i=0;i<count*4;++i) bytes[i]=static_cast<uint8_t>(words[i/4]>>(8*(i%4)));
}
void ed_reduce(uint8_t* out,const uint8_t* input,size_t length) {
  uint32_t result[8];reduce_bytes(input,length,ed_order,8,result);words_bytes(result,8,out);wipe(result,sizeof(result));
}
struct EdPoint {Field x,y,z,t;};
void ed_add(EdPoint& result,const EdPoint& left,const EdPoint& right) {
  struct Work {Field a,b,c,d,e,f,g,h,temp,u;} w{};
  sub(w.temp,left.y,left.x);sub(w.u,right.y,right.x);mul(w.a,w.temp,w.u);
  add(w.temp,left.y,left.x);add(w.u,right.y,right.x);mul(w.b,w.temp,w.u);
  mul(w.temp,left.t,right.t);mul(w.c,w.temp,ed_d2);mul(w.temp,left.z,right.z);add(w.d,w.temp,w.temp);
  sub(w.e,w.b,w.a);sub(w.f,w.d,w.c);add(w.g,w.d,w.c);add(w.h,w.b,w.a);
  mul(result.x,w.e,w.f);mul(result.y,w.g,w.h);mul(result.z,w.f,w.g);mul(result.t,w.e,w.h);
  wipe(&w,sizeof(w));
}
void ed_multiply(uint8_t* out,const uint8_t* scalar) {
  EdPoint result{},power{},added{};result.y[0]=1;result.z[0]=1;
  std::memcpy(power.x,ed_base_x,sizeof(Field));std::memcpy(power.y,ed_base_y,sizeof(Field));power.z[0]=1;mul(power.t,power.x,power.y);
  for(unsigned bit=0;bit<256;++bit) {
    ed_add(added,result,power);
    int64_t choice=(scalar[bit/8]>>(bit%8))&1;
    swap(result.x,added.x,choice);swap(result.y,added.y,choice);swap(result.z,added.z,choice);swap(result.t,added.t,choice);
    ed_add(power,power,power);
  }
  Field reciprocal,x,y;inverse(reciprocal,result.z);mul(x,result.x,reciprocal);mul(y,result.y,reciprocal);
  uint8_t xbytes[32];pack(out,y);pack(xbytes,x);out[31]|=(xbytes[0]&1)<<7;
  wipe(&result,sizeof(result));wipe(&power,sizeof(power));wipe(&added,sizeof(added));
  wipe(reciprocal,sizeof(reciprocal));wipe(x,sizeof(x));wipe(y,sizeof(y));wipe(xbytes,sizeof(xbytes));
}
bool equal_bytes(const uint8_t* a,const uint8_t* b,size_t n) {
  uint8_t difference=0;for(size_t i=0;i<n;++i) difference|=a[i]^b[i];return difference==0;
}
struct SigningKey {
  int kind=0;uint8_t seed[32]{},public_key[32]{};
  unsigned size=0,words=0;uint32_t exponent=0,inverse_word=0;
  uint32_t modulus[rsa_max_words]{},private_exponent[rsa_max_words]{},r2[rsa_max_words]{};
};
bool ed_sign(const SigningKey& key,const uint8_t* message,size_t length,uint8_t* output) {
  uint8_t digest[64],r[32],h[32],wide[64];uint32_t product[64]{};
  uint8_t* buffer=static_cast<uint8_t*>(std::malloc(length+64));if(!buffer)return false;
  hash512(key.seed,32,digest);digest[0]&=248;digest[31]=(digest[31]&63)|64;
  std::memcpy(buffer,digest+32,32);if(length)std::memcpy(buffer+32,message,length);
  hash512(buffer,length+32,wide);ed_reduce(r,wide,64);ed_multiply(output,r);
  std::memcpy(buffer,output,32);std::memcpy(buffer+32,key.public_key,32);if(length)std::memcpy(buffer+64,message,length);
  hash512(buffer,length+64,wide);ed_reduce(h,wide,64);
  for(unsigned i=0;i<32;++i) for(unsigned j=0;j<32;++j) product[i+j]+=static_cast<uint32_t>(h[i])*digest[j];
  for(unsigned i=0;i<32;++i) product[i]+=r[i];
  for(unsigned i=0;i<63;++i){product[i+1]+=product[i]>>8;wide[i]=static_cast<uint8_t>(product[i]);}
  wide[63]=static_cast<uint8_t>(product[63]);ed_reduce(output+32,wide,64);
  wipe(buffer,length+64);std::free(buffer);wipe(digest,sizeof(digest));wipe(r,sizeof(r));wipe(h,sizeof(h));wipe(wide,sizeof(wide));wipe(product,sizeof(product));return true;
}

void multiply_words(const uint32_t* a,const uint32_t* b,unsigned count,uint32_t* product) {
  std::memset(product,0,(count*2+2)*4);
  for(unsigned i=0;i<count;++i) {
    uint64_t carry_word=0;
    for(unsigned j=0;j<count;++j) {
      uint64_t v=static_cast<uint64_t>(a[i])*b[j]+product[i+j]+carry_word;
      product[i+j]=static_cast<uint32_t>(v);carry_word=v>>32;
    }
    product[i+count]=static_cast<uint32_t>(carry_word);
  }
}
void montgomery(const SigningKey& key,const uint32_t* a,const uint32_t* b,uint32_t* result) {
  uint32_t t[2*rsa_max_words+2]{},difference[rsa_max_words];unsigned n=key.words;
  multiply_words(a,b,n,t);
  for(unsigned i=0;i<n;++i) {
    uint32_t factor=t[i]*key.inverse_word;uint64_t carry_word=0;
    for(unsigned j=0;j<n;++j) {
      uint64_t v=static_cast<uint64_t>(factor)*key.modulus[j]+t[i+j]+carry_word;
      t[i+j]=static_cast<uint32_t>(v);carry_word=v>>32;
    }
    for(unsigned j=i+n;j<2*n+2;++j) {
      uint64_t v=static_cast<uint64_t>(t[j])+carry_word;t[j]=static_cast<uint32_t>(v);carry_word=v>>32;
    }
  }
  uint64_t borrow=0;
  for(unsigned i=0;i<n;++i) {
    uint64_t v=static_cast<uint64_t>(t[n+i])-key.modulus[i]-borrow;
    difference[i]=static_cast<uint32_t>(v);borrow=v>>63;
  }
  uint32_t mask=0-static_cast<uint32_t>(1-((static_cast<uint64_t>(t[2*n])-borrow)>>63));
  for(unsigned i=0;i<n;++i)result[i]=(difference[i]&mask)|(t[n+i]&~mask);
  wipe(t,sizeof(t));wipe(difference,sizeof(difference));
}
void rsa_power(const SigningKey& key,const uint32_t* base,const uint32_t* exponent,unsigned bits,uint32_t* output) {
  struct Work {uint32_t one[rsa_max_words],value[rsa_max_words],power[rsa_max_words],square[rsa_max_words],product[rsa_max_words];} w{};
  w.one[0]=1;montgomery(key,w.one,key.r2,w.value);montgomery(key,base,key.r2,w.power);
  for(unsigned i=bits;i>0;--i) {
    montgomery(key,w.value,w.value,w.square);montgomery(key,w.square,w.power,w.product);
    uint32_t mask=0-((exponent[(i-1)/32]>>((i-1)%32))&1);
    for(unsigned j=0;j<key.words;++j)w.value[j]=(w.product[j]&mask)|(w.square[j]&~mask);
  }
  montgomery(key,w.value,w.one,output);wipe(&w,sizeof(w));
}
void reduce_words(const uint32_t* value,unsigned count,const uint32_t* modulus,unsigned n,uint32_t* result) {
  std::memset(result,0,n*4);
  for(unsigned i=count;i>0;--i)for(int bit=31;bit>=0;--bit)shift_mod(result,modulus,n,(value[i-1]>>bit)&1);
}
struct NumberReader {
  const uint8_t* bytes;size_t size,offset;
  bool number(uint32_t* out,unsigned words,size_t* length=nullptr) {
    if(size-offset<4)return false;size_t n=static_cast<size_t>(load_be(bytes+offset,4));offset+=4;
    if(n==0||n>words*4||n>size-offset||bytes[offset]==0)return false;
    std::memset(out,0,words*4);
    for(size_t i=0;i<n;++i)out[i/4]|=static_cast<uint32_t>(bytes[offset+n-1-i])<<(8*(i%4));
    offset+=n;if(length)*length=n;return true;
  }
};
bool rsa_initialize(SigningKey& key,const uint8_t* bytes,size_t length) {
  struct Work {uint32_t p[rsa_max_words],q[rsa_max_words],iq[rsa_max_words],pm[rsa_max_words],qm[rsa_max_words],product[2*rsa_max_words+2],reduced[rsa_max_words],e[rsa_max_words];} w{};
  NumberReader reader{bytes,length,0};size_t size=0;
  bool valid=reader.number(key.modulus,rsa_max_words,&size)&&size>=256&&size<=512&&(size>256||(key.modulus[63]&0x80000000));
  key.size=static_cast<unsigned>(size);key.words=(key.size+3)/4;
  valid=valid&&reader.number(w.e,1)&&w.e[0]>=3&&(w.e[0]&1)&&reader.number(key.private_exponent,key.words)&&reader.number(w.p,key.words)&&reader.number(w.q,key.words)&&reader.number(w.iq,key.words)&&reader.offset==length;
  valid=valid&&(key.modulus[0]&1)&&(w.p[0]&1)&&(w.q[0]&1);
  uint32_t p_other=0,q_other=0;for(unsigned i=1;i<rsa_max_words;++i){p_other|=w.p[i];q_other|=w.q[i];}
  valid=valid&&(w.p[0]>1||p_other)&&(w.q[0]>1||q_other);
  if(!valid){wipe(&w,sizeof(w));return false;}
  key.exponent=w.e[0];unsigned n=key.words;
  multiply_words(w.p,w.q,n,w.product);uint32_t difference=0;
  for(unsigned i=0;i<n;++i)difference|=w.product[i]^key.modulus[i];for(unsigned i=n;i<2*n+2;++i)difference|=w.product[i];
  uint64_t bp=1,bq=1;
  for(unsigned i=0;i<n;++i){uint64_t p=static_cast<uint64_t>(w.p[i])-bp,q=static_cast<uint64_t>(w.q[i])-bq;w.pm[i]=static_cast<uint32_t>(p);w.qm[i]=static_cast<uint32_t>(q);bp=p>>63;bq=q>>63;}
  multiply_words(key.private_exponent,w.e,n,w.product);
  // RFC 8017: e*d = 1 modulo lcm(p-1,q-1), not necessarily modulo phi(n).
  reduce_words(w.product,2*n+2,w.pm,n,w.reduced);
  difference|=w.reduced[0]^1;for(unsigned i=1;i<n;++i)difference|=w.reduced[i];
  reduce_words(w.product,2*n+2,w.qm,n,w.reduced);
  difference|=w.reduced[0]^1;for(unsigned i=1;i<n;++i)difference|=w.reduced[i];
  uint64_t d_borrow=0;for(unsigned i=0;i<n;++i){uint64_t v=static_cast<uint64_t>(key.private_exponent[i])-key.modulus[i]-d_borrow;d_borrow=v>>63;}difference|=static_cast<uint32_t>(1-d_borrow);
  multiply_words(w.q,w.iq,n,w.product);reduce_words(w.product,2*n+2,w.p,n,w.reduced);
  difference|=w.reduced[0]^1;for(unsigned i=1;i<n;++i)difference|=w.reduced[i];
  if(difference){wipe(&w,sizeof(w));return false;}
  // Newton inverse of the public odd low modulus word, modulo 2^32.
  uint32_t inverse_word=1;for(unsigned i=0;i<5;++i)inverse_word*=2-key.modulus[0]*inverse_word;key.inverse_word=0-inverse_word;
  key.r2[0]=1;for(unsigned i=0;i<n*64;++i)shift_mod(key.r2,key.modulus,n,0);
  wipe(&w,sizeof(w));return true;
}
bool rsa_sign(const SigningKey& key,int bits,const uint8_t* message,size_t length,uint8_t* output) {
  if(bits!=256&&bits!=512)return false;
  uint8_t encoded[512]{},digest[64];uint32_t base[rsa_max_words]{},signature[rsa_max_words]{},verified[rsa_max_words]{},exponent[rsa_max_words]{};
  const uint8_t prefix[19]={0x30,static_cast<uint8_t>(bits==256?0x31:0x51),0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,static_cast<uint8_t>(bits==256?1:3),0x05,0x00,0x04,static_cast<uint8_t>(bits/8)};
  unsigned hash_size=static_cast<unsigned>(bits/8),separator=key.size-19-hash_size-1;
  encoded[1]=1;std::memset(encoded+2,0xff,separator-2);std::memcpy(encoded+separator+1,prefix,19);
  if(bits==256)hash256(message,length,digest);else hash512(message,length,digest);std::memcpy(encoded+key.size-hash_size,digest,hash_size);
  for(unsigned i=0;i<key.size;++i)base[i/4]|=static_cast<uint32_t>(encoded[key.size-1-i])<<(8*(i%4));
  rsa_power(key,base,key.private_exponent,key.words*32,signature);exponent[0]=key.exponent;rsa_power(key,signature,exponent,32,verified);
  uint32_t difference=0;for(unsigned i=0;i<key.words;++i)difference|=base[i]^verified[i];
  if(!difference)for(unsigned i=0;i<key.size;++i)output[key.size-1-i]=static_cast<uint8_t>(signature[i/4]>>(8*(i%4)));
  wipe(encoded,sizeof(encoded));wipe(digest,sizeof(digest));wipe(base,sizeof(base));wipe(signature,sizeof(signature));wipe(verified,sizeof(verified));wipe(exponent,sizeof(exponent));return difference==0;
}
