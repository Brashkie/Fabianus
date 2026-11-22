--  SPDX-License-Identifier: GPL-3.0-or-later
--  Frontera de la paginación con el resto de lenguajes.
--
--  Construye las tablas del kernel en una sola llamada: así la invariante de
--  Page_Tree se establece y se mantiene dentro de código demostrado, sin tener
--  que suponerla al entrar desde otro lenguaje.

with Page_Tree; use Page_Tree;

package Paging_Gate with
  SPARK_Mode,
  Abstract_State => State,
  Initializes    => State
is
   Max_Regions : constant := 32;

   type Region is record
      Va     : U64;
      Pa     : U64;
      Length : U64;
      Perm   : U64;
      Size   : U64;
   end record with Convention => C;

   type Region_Index is range 0 .. Max_Regions - 1;
   type Region_Table is array (Region_Index) of Region with Convention => C;

   Status_Ok            : constant U64 := 0;
   Status_Invalid       : constant U64 := 1;
   Status_No_Space      : constant U64 := 2;
   Status_Conflict      : constant U64 := 3;
   Status_Already_Built : constant U64 := 4;

   function Build
     (Regions   : Region_Table;
      Count     : U64;
      Pool_Base : U64) return U64
   with
     Side_Effects,
     Global        => (In_Out => State),
     Export,
     Convention    => C,
     External_Name => "fb_paging_build";

end Paging_Gate;
