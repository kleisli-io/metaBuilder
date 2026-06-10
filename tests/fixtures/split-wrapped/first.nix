{ api, ... }:

{
  scope = {
    x = api.leaf {
      description = "documented x";
      value = 1;
    };
  };
}
