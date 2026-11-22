--  SPDX-License-Identifier: GPL-3.0-or-later
--  Frontera del asignador con el resto de lenguajes.
--
--  Los demás lenguajes no pueden demostrar las precondiciones de Frame_Bitmap,
--  así que aquí cada argumento se comprueba en tiempo de ejecución. GNATprove
--  demuestra que, tras esas comprobaciones, los contratos del núcleo se cumplen.

package Frame_Gate with
  SPARK_Mode,
  Abstract_State => State,
  Initializes    => State
is
   type U64 is mod 2**64 with Size => 64;

   Status_Ok           : constant U64 := 0;
   Status_Misaligned   : constant U64 := 1;
   Status_Out_Of_Range : constant U64 := 2;
   Status_Not_Assigned : constant U64 := 3;
   Status_Already_Init : constant U64 := 4;

   function Init (Base : U64; Count : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Export,
     Convention    => C,
     External_Name => "fb_frames_init";

   --  Devuelve la dirección física de un marco, o 0 si no queda ninguno.
   function Alloc return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Export,
     Convention    => C,
     External_Name => "fb_frames_alloc";

   function Free (Address : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Export,
     Convention    => C,
     External_Name => "fb_frames_free";

end Frame_Gate;
