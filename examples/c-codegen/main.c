#include <stdio.h>

#include "config.h"
#include "generated_messages.h"

int main(void) {
  printf("%s\n", message_hello());
  return DEMO_FEATURE ? 0 : 1;
}
