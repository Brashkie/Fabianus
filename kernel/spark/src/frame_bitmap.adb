package body Frame_Bitmap with
  SPARK_Mode
is

   --  Máscara con los bits de la última palabra que están dentro del límite.
   function Last_Mask (Limit : Frame_Index) return Word is
     (Shift_Right (Word'Last, 63 - Natural (Limit mod Bits_Per_Word)));

   --  La palabra W con los bits más allá del límite a cero.
   function Masked
     (Map   : Free_Map;
      W     : Word_Index;
      Limit : Frame_Index) return Word
   is
     (if W = Word_Of (Limit) then Map (W) and Last_Mask (Limit) else Map (W));

   --  Búsqueda binaria de un bit a 1. RV64IMAC no tiene instrucción para esto.
   function Lowest_Bit (Value : Word) return Bit_Number with
     Inline,
     Pre  => Value /= 0,
     Post => (Value and Shift_Left (1, Lowest_Bit'Result)) /= 0
   is
      Rest : Word       := Value;
      Bit  : Bit_Number := 0;
   begin
      if (Rest and 16#FFFF_FFFF#) = 0 then
         Rest := Shift_Right (Rest, 32);
         Bit  := Bit + 32;
      end if;
      pragma Assert (Rest = Shift_Right (Value, Bit) and Rest /= 0 and Bit <= 32);

      if (Rest and 16#FFFF#) = 0 then
         Rest := Shift_Right (Rest, 16);
         Bit  := Bit + 16;
      end if;
      pragma Assert (Rest = Shift_Right (Value, Bit) and Rest /= 0 and Bit <= 48);

      if (Rest and 16#FF#) = 0 then
         Rest := Shift_Right (Rest, 8);
         Bit  := Bit + 8;
      end if;
      pragma Assert (Rest = Shift_Right (Value, Bit) and Rest /= 0 and Bit <= 56);

      if (Rest and 16#F#) = 0 then
         Rest := Shift_Right (Rest, 4);
         Bit  := Bit + 4;
      end if;
      pragma Assert (Rest = Shift_Right (Value, Bit) and Rest /= 0 and Bit <= 60);

      if (Rest and 16#3#) = 0 then
         Rest := Shift_Right (Rest, 2);
         Bit  := Bit + 2;
      end if;
      pragma Assert (Rest = Shift_Right (Value, Bit) and Rest /= 0 and Bit <= 62);

      if (Rest and 1) = 0 then
         Rest := Shift_Right (Rest, 1);
         Bit  := Bit + 1;
      end if;
      pragma Assert (Rest = Shift_Right (Value, Bit) and (Rest and 1) = 1);

      return Bit;
   end Lowest_Bit;

   procedure Find_Word
     (Map   : Free_Map;
      Limit : Frame_Index;
      From  : Word_Index;
      To    : Word_Index;
      Found : out Boolean;
      Index : out Word_Index)
   with
     Inline,
     Pre  => From <= To and then To <= Word_Of (Limit),
     Post =>
       (if Found
        then Index in From .. To and then Masked (Map, Index, Limit) /= 0
        else (for all W in From .. To => Masked (Map, W, Limit) = 0))
   is
   begin
      Found := False;
      Index := From;

      for Candidate in From .. To loop
         if Masked (Map, Candidate, Limit) /= 0 then
            Found := True;
            Index := Candidate;
            return;
         end if;

         pragma Loop_Invariant
           (for all W in From .. Candidate => Masked (Map, W, Limit) = 0);
      end loop;
   end Find_Word;

   --  Si la palabra de F no tiene bits disponibles, F no está libre.
   procedure Lemma_Empty_Word
     (Map   : Free_Map;
      Limit : Frame_Index;
      F     : Frame_Index)
   with
     Ghost,
     Pre  => F <= Limit and then Masked (Map, Word_Of (F), Limit) = 0,
     Post => not Is_Free (Map, F)
   is
   begin
      if Word_Of (F) = Word_Of (Limit) then
         pragma Assert (F mod Bits_Per_Word <= Limit mod Bits_Per_Word);
         pragma Assert ((Last_Mask (Limit) and Bit_Of (F)) = Bit_Of (F));
      end if;
   end Lemma_Empty_Word;

   --  Un bit disponible en la última palabra está dentro del límite.
   procedure Lemma_Masked_Bit_Within_Limit
     (Value : Word;
      Limit : Frame_Index;
      Bit   : Bit_Number)
   with
     Ghost,
     Pre  => (Value and Last_Mask (Limit) and Shift_Left (1, Bit)) /= 0,
     Post => Bit <= Natural (Limit mod Bits_Per_Word)
   is
   begin
      null;
   end Lemma_Masked_Bit_Within_Limit;

   --  Marca un marco libre como asignado. Es el único que cambia.
   procedure Take (Map : in out Free_Map; Frame : Frame_Index) with
     Inline,
     Pre  => Is_Free (Map, Frame),
     Post =>
       not Is_Free (Map, Frame)
       and then
         (for all F in Frame_Index =>
            (if F /= Frame then Is_Free (Map, F) = Is_Free (Map'Old, F)))
   is
   begin
      Map (Word_Of (Frame)) := Map (Word_Of (Frame)) and not Bit_Of (Frame);
   end Take;

   procedure Mark_Usable (Map : in out Free_Map; Count : Frame_Total) is
   begin
      if Count = 0 then
         return;
      end if;

      for F in 0 .. Count - 1 loop
         Map (Word_Of (F)) := Map (Word_Of (F)) or Bit_Of (F);

         pragma Loop_Invariant
           (for all G in Frame_Index =>
              Is_Free (Map, G)
                = (if G <= F then True else Is_Free (Map'Loop_Entry, G)));
      end loop;
   end Mark_Usable;

   procedure Allocate
     (Map   : in out Free_Map;
      Limit : Frame_Index;
      Hint  : Frame_Index;
      Found : out Boolean;
      Frame : out Frame_Index)
   is
      Last  : constant Word_Index := Word_Of (Limit);
      Start : constant Word_Index := Word_Of (Hint);
      Index : Word_Index;
   begin
      --  Vía rápida: en el uso normal, el marco sugerido suele estar libre.
      if Is_Free (Map, Hint) then
         Found := True;
         Frame := Hint;
         Take (Map, Frame);
         return;
      end if;

      Frame := 0;
      Find_Word (Map, Limit, Start, Last, Found, Index);

      if not Found and then Start > 0 then
         Find_Word (Map, Limit, 0, Start - 1, Found, Index);
      end if;

      if not Found then
         pragma Assert
           (for all W in 0 .. Last => Masked (Map, W, Limit) = 0);

         for F in 0 .. Limit loop
            Lemma_Empty_Word (Map, Limit, F);
            pragma Loop_Invariant
              (for all G in 0 .. F => not Is_Free (Map, G));
         end loop;
         return;
      end if;

      declare
         Available : constant Word       := Masked (Map, Index, Limit);
         Bit       : constant Bit_Number := Lowest_Bit (Available);
      begin
         if Index = Last then
            Lemma_Masked_Bit_Within_Limit (Map (Index), Limit, Bit);
         end if;

         Frame := Frame_Total (Index) * Bits_Per_Word + Frame_Total (Bit);
         pragma Assert (Word_Of (Frame) = Index);
         pragma Assert (Bit_Of (Frame) = Shift_Left (1, Bit));
         pragma Assert ((Map (Index) and Shift_Left (1, Bit)) /= 0);
         pragma Assert (Is_Free (Map, Frame));

         Take (Map, Frame);
      end;
   end Allocate;

   procedure Release (Map : in out Free_Map; Frame : Frame_Index) is
   begin
      Map (Word_Of (Frame)) := Map (Word_Of (Frame)) or Bit_Of (Frame);
   end Release;

   procedure Lemma_Allocations_Are_Distinct
     (Map    : in out Free_Map;
      Limit  : Frame_Index;
      Hint_1 : Frame_Index;
      Hint_2 : Frame_Index;
      Found_1, Found_2 : out Boolean;
      Frame_1, Frame_2 : out Frame_Index)
   is
   begin
      Allocate (Map, Limit, Hint_1, Found_1, Frame_1);
      Allocate (Map, Limit, Hint_2, Found_2, Frame_2);
   end Lemma_Allocations_Are_Distinct;

end Frame_Bitmap;
