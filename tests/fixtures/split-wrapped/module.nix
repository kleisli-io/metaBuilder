{ api, self, partTests, ... }:

api.mk {
  value = self;
  tests = partTests;
}
