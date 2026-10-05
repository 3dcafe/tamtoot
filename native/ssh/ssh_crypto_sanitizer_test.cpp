#include <cstdio>
// Standalone sanitizer test, never linked into the application.
#include "ssh_crypto.cpp"
static void from_hex(const char* source,uint8_t* output,unsigned size) {
  for(unsigned i=0;i<size;++i){ unsigned value=0; std::sscanf(source+2*i,"%2x",&value);output[i]=uint8_t(value); }
}
int main() {
  uint8_t material[64],signature[64],expected[64],derived[32];
  from_hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",material,64);
  from_hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",expected,64);
  void* signer=tamtoot_ssh_signer_create(1,material,64);
  if(!signer||!tamtoot_ssh_signer_sign(signer,0,material,0,signature,64)||std::memcmp(signature,expected,64))return 6;
  tamtoot_ssh_signer_free(signer);
  material[63]^=1;
  if(tamtoot_ssh_signer_create(1,material,64))return 7;
  from_hex("5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9",expected,32);
  if(!tamtoot_ssh_bcrypt(reinterpret_cast<const uint8_t*>("password"),8,reinterpret_cast<const uint8_t*>("salt"),4,4,derived,32)||std::memcmp(derived,expected,32))return 8;

  uint8_t pubA[32],pubB[32],a[32],b[32],key[32],iv[16],input[129],encoded[129],decoded[129],hash[64];
  for (unsigned iteration=0;iteration<100;++iteration) {
    void* left=tamtoot_ssh_exchange_create(pubA);void* right=tamtoot_ssh_exchange_create(pubB);
    if(!left||!right||!tamtoot_ssh_exchange_shared(left,pubB,a)||!tamtoot_ssh_exchange_shared(right,pubA,b)||std::memcmp(a,b,32))return 1;
    tamtoot_ssh_exchange_free(left);tamtoot_ssh_exchange_free(right);
    if(!tamtoot_ssh_random(key,32)||!tamtoot_ssh_random(iv,16)||!tamtoot_ssh_random(input,129))return 2;
    void* encrypt=tamtoot_ssh_cipher_create(key,iv);void* decrypt=tamtoot_ssh_cipher_create(key,iv);
    for(unsigned offset=0;offset<129;++offset)if(!tamtoot_ssh_cipher_apply(encrypt,input+offset,1,encoded+offset))return 3;
    if(!tamtoot_ssh_cipher_apply(decrypt,encoded,129,decoded)||std::memcmp(input,decoded,129))return 4;
    tamtoot_ssh_cipher_free(encrypt);tamtoot_ssh_cipher_free(decrypt);
    for(unsigned size=0;size<129;++size)if(!tamtoot_ssh_hash(256,input,size,hash)||!tamtoot_ssh_hash(512,input,size,hash))return 5;
  }
}
