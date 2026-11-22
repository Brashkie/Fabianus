--  SPDX-License-Identifier: GPL-3.0-or-later
--  Núcleo demostrado del asignador de marcos físicos.
--
--  No tiene estado global: cada operación recibe el mapa y su contrato describe
--  exactamente cómo cambia. Un bit a 1 significa que el marco está libre, de
--  modo que un mapa a cero (.bss) es seguro: no hay nada que asignar.
--
--  Busca por palabras de 64 bits. Con n marcos: Allocate cuesta O(n / 64) en el
--  peor caso más O(log 64) para localizar el bit, y Release es O(1).

package Frame_Bitmap with
  SPARK_Mode,
  Preelaborate
is
   Max_Frames    : constant := 32_768;
   Bits_Per_Word : constant := 64;

   type Frame_Total is range 0 .. Max_Frames;
   subtype Frame_Index is Frame_Total range 0 .. Max_Frames - 1;

   type Word is mod 2**64 with Size => 64;
   subtype Bit_Number is Natural range 0 .. Bits_Per_Word - 1;

   function Shift_Left (Value : Word; Amount : Natural) return Word with
     Import, Convention => Intrinsic, Global => null;

   function Shift_Right (Value : Word; Amount : Natural) return Word with
     Import, Convention => Intrinsic, Global => null;

   type Word_Index is range 0 .. Max_Frames / Bits_Per_Word - 1;
   type Free_Map is array (Word_Index) of Word;

   function Word_Of (F : Frame_Index) return Word_Index is
     (Word_Index (F / Bits_Per_Word));

   function Bit_Of (F : Frame_Index) return Word is
     (Shift_Left (1, Natural (F mod Bits_Per_Word)));

   function Is_Free (Map : Free_Map; F : Frame_Index) return Boolean is
     ((Map (Word_Of (F)) and Bit_Of (F)) /= 0);

   --  Marca como libres los marcos 0 .. Count - 1 y no toca el resto.
   procedure Mark_Usable (Map : in out Free_Map; Count : Frame_Total) with
     Post =>
       (for all F in Frame_Index =>
          Is_Free (Map, F)
            = (if F < Count then True else Is_Free (Map'Old, F)));

   --  Busca un marco libre en 0 .. Limit empezando cerca de Hint.
   --  Si lo encuentra, ese marco estaba libre y es el único que cambia.
   --  Si no lo encuentra, es porque realmente no queda ninguno.
   procedure Allocate
     (Map   : in out Free_Map;
      Limit : Frame_Index;
      Hint  : Frame_Index;
      Found : out Boolean;
      Frame : out Frame_Index)
   with
     Inline,
     Pre  => Hint <= Limit,
     Post =>
       (if Found
        then Frame <= Limit
          and then Is_Free (Map'Old, Frame)
          and then not Is_Free (Map, Frame)
          and then
            (for all F in Frame_Index =>
               (if F /= Frame then Is_Free (Map, F) = Is_Free (Map'Old, F)))
        else Map = Map'Old
          and then (for all F in 0 .. Limit => not Is_Free (Map, F)));

   --  Libera un marco asignado. Es el único que cambia.
   procedure Release (Map : in out Free_Map; Frame : Frame_Index) with
     Inline,
     Pre  => not Is_Free (Map, Frame),
     Post =>
       Is_Free (Map, Frame)
       and then
         (for all F in Frame_Index =>
            (if F /= Frame then Is_Free (Map, F) = Is_Free (Map'Old, F)));

   --  Teorema: dos asignaciones seguidas nunca entregan el mismo marco.
   --  Solo existe para la demostración; no genera código.
   procedure Lemma_Allocations_Are_Distinct
     (Map    : in out Free_Map;
      Limit  : Frame_Index;
      Hint_1 : Frame_Index;
      Hint_2 : Frame_Index;
      Found_1, Found_2 : out Boolean;
      Frame_1, Frame_2 : out Frame_Index)
   with
     Ghost,
     Pre  => Hint_1 <= Limit and Hint_2 <= Limit,
     Post => (if Found_1 and Found_2 then Frame_1 /= Frame_2);

end Frame_Bitmap;
