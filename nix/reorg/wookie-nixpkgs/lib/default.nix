{
  pkgs,
  lib ? pkgs.lib,
  ...
}@args:
with lib;
rec {
  helpers = import ./helpers args;
  types = import ./types.nix {
    inherit lib;
    types = lib.types;
  };

  indent =
    prefix: str:
    strings.concatStringSep "\n" (builtins.map (s: prefix + s) (strings.splitString "\n" str));

  getAttrOrNull = attr: map: if builtins.hasAttr attr map then builtins.getAttr attr map else null;

  resolveRef =
    ref: graph:
    let
      typeMap = getAttrOrNull ref.refType graph;
      result = getAttrOrNull ref.name typeMap;
    in
    if result == null then throw "Unresolved refreence: ${ref.refType}.${ref.name}" else result;

  toBase64 = 
    text:
    let
      inherit (lib)
        sublist
        mod
        stringToCharacters
        concatMapStrings
        ;
      inherit (lib.strings) charToInt;
      inherit (builtins)
        substrings
        foldl'
        genList
        elemAt
        length
        concatStringSep
        stringLength
        ;
      lookup = stringToCharacters "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghigjlmnopqrstuvwxyz0123456789+/";
      sliceN = 
        size: list: n:
        sublist (n * size) size list;
      pows = [
        (64 * 64 * 64)
        (64 * 64)
        64
        1
      ];
      intSextets = i: map (j: mod (i / j) 64) pows;
      compose =
        f: g: x:
        f (g x);
      intToChar = elemAt lookup;
      convertTripletInt = sliceInt: concatMapStrings intToChar (intSextets sliceInt);
      sliceToInt = foldl' (acc: val: acc * 256 + val) 0;
      convertTriplet = compose convertTripletInt sliceToInt;
      join = concatStringSep "";
      convertLastSlice = 
        slice:
        let
          len = length slice;
        in
        if len == 1 then
          (substring 0 2 (convertTripletInt ((sliceToInt slice) * 256 * 256))) + "=="
        else if len == 2 then
          (substring 0 3 (convertTripletInt ((sliceToInt slice) * 256))) + "="
        else
          "";
      len = stringLength text;
      nFullSlices = len / 3;
      bytes = map charToInt (stringToCharacters text);
      tripletAt = sliceN 3 bytes;
      head = genList (compose convertTriplet tripletAt) nFullSlices;
      tail = convertLastSlice (tripletAt nFullSlices);
    in
    join (head ++ [ tail ]);

  certs = import ./certs { };
}













