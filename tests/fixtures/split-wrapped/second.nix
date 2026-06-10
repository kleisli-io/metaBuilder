{ mb, self, ... }:

{
  scope = {
    y = self.x + 1;
    rootHasOperations = mb ? operations;
  };
}
