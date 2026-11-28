--  SPDX-License-Identifier: GPL-3.0-or-later
package body Fs_Handles with
  SPARK_Mode
is

   procedure Lemma_Step_Owner
     (Old, New_T : Handle_Table; Step, Badge, Handle, File, Gen : U64)
   is
   begin
      for C in Client_Index loop
         if New_T (C).Badge = Badge
           and then Is_Open (New_T (C).Opens (Open_Index (Handle)))
           and then U64 (New_T (C).Opens (Open_Index (Handle)).File) = File
           and then U64 (New_T (C).Opens (Open_Index (Handle)).Gen) = Gen
         then
            --  Con la fila igual, ya lo tenía antes.
            pragma Assert (Old (C) /= New_T (C));
            return;
         end if;
         pragma Loop_Invariant
           (for all D in Client_Index'First .. C =>
              not (New_T (D).Badge = Badge
                   and then Is_Open (New_T (D).Opens (Open_Index (Handle)))
                   and then U64 (New_T (D).Opens (Open_Index (Handle)).File) = File
                   and then U64 (New_T (D).Opens (Open_Index (Handle)).Gen) = Gen));
      end loop;
   end Lemma_Step_Owner;

   procedure Lemma_Only_Owner
     (H : History; B : Badge_List; Badge, Handle, File, Gen : U64)
   is
   begin
      for K in H'First .. H'Last - 1 loop
         pragma Loop_Invariant (not Holds (H (K), Badge, Handle, File, Gen));
         if Holds (H (K + 1), Badge, Handle, File, Gen) then
            Lemma_Step_Owner (H (K), H (K + 1), B (K), Badge, Handle, File, Gen);
            pragma Assert (B (K) = Badge);
            return;
         end if;
         pragma Assert (not Holds (H (K + 1), Badge, Handle, File, Gen));
      end loop;
      --  Con un solo elemento, el principio y el final son la misma tabla.
      pragma Assert (H'First = H'Last);
   end Lemma_Only_Owner;

   procedure Clear (T : out Handle_Table) is
   begin
      T := (others => (Badge => 0, Opens => (others => Closed)));
   end Clear;

   --  La fila del cliente Badge, si tiene una.
   procedure Find_Row
     (T : Handle_Table; Badge : U64; Row : out Client_Index; Found : out Boolean)
   with
     Global => null,
     Post   =>
       (if Found then T (Row).Badge = Badge
        else (for all C in Client_Index => T (C).Badge /= Badge))
   is
   begin
      Row := Client_Index'First;
      for C in Client_Index loop
         if T (C).Badge = Badge then
            Row := C;
            Found := True;
            return;
         end if;
         pragma Loop_Invariant
           (for all D in Client_Index'First .. C => T (D).Badge /= Badge);
      end loop;
      Found := False;
   end Find_Row;

   function Room (T : Handle_Table; Badge : U64) return U64 is
      Row   : Client_Index;
      Found : Boolean;
   begin
      if Badge = 0 then
         return 0;
      end if;
      Find_Row (T, Badge, Row, Found);
      if not Found then
         --  Sin fila: hace falta una libre.
         for C in Client_Index loop
            if T (C).Badge = 0 then
               return 1;
            end if;
            pragma Loop_Invariant
              (for all D in Client_Index'First .. C => T (D).Badge /= 0);
         end loop;
         return 0;
      end if;
      for H in Open_Index loop
         if not Is_Open (T (Row).Opens (H)) then
            return 1;
         end if;
         pragma Loop_Invariant
           (for all G in Open_Index'First .. H => Is_Open (T (Row).Opens (G)));
      end loop;
      return 0;
   end Room;

   procedure Open
     (T : in out Handle_Table; Badge, File, Gen : U64;
      Handle : out U64; Status : out U64)
   is
      Row   : Client_Index;
      Found : Boolean;
   begin
      Handle := 0;
      if Badge = 0 then
         Status := Status_Denied;
         return;
      end if;
      if File >= Max_Files or else Gen > U64 (U32'Last) then
         Status := Status_Request;
         return;
      end if;

      Find_Row (T, Badge, Row, Found);
      if not Found then
         --  Una fila libre: no tiene nada abierto.
         Find_Row (T, 0, Row, Found);
         if not Found then
            Status := Status_Handles;
            return;
         end if;
      end if;

      for H in Open_Index loop
         if not Is_Open (T (Row).Opens (H)) then
            pragma Assert (not Is_Held (T, Badge, U64 (H)));
            T (Row).Badge := Badge;
            T (Row).Opens (H) :=
              (Used => 1, File => U32 (File), Gen => U32 (Gen), Pad => 0);
            Handle := U64 (H);
            Status := Status_Ok;
            return;
         end if;
         pragma Loop_Invariant
           (for all G in Open_Index'First .. H => Is_Open (T (Row).Opens (G)));
      end loop;
      Status := Status_Handles;
   end Open;

   procedure Resolve
     (T : Handle_Table; Badge, Handle : U64; File, Gen, Status : out U64)
   is
      Row   : Client_Index;
      Found : Boolean;
   begin
      File := 0;
      Gen := 0;
      if Badge = 0 then
         Status := Status_Denied;
         return;
      end if;
      if Handle >= Max_Open then
         Status := Status_Bad_Handle;
         return;
      end if;

      Find_Row (T, Badge, Row, Found);
      if not Found
        or else not Is_Open (T (Row).Opens (Open_Index (Handle)))
      then
         Status := Status_Bad_Handle;
         return;
      end if;

      File := U64 (T (Row).Opens (Open_Index (Handle)).File);
      Gen := U64 (T (Row).Opens (Open_Index (Handle)).Gen);
      Status := Status_Ok;
   end Resolve;

   procedure Close
     (T : in out Handle_Table; Badge, Handle : U64; Status : out U64)
   is
      Row   : Client_Index;
      Found : Boolean;
   begin
      if Badge = 0 then
         Status := Status_Denied;
         return;
      end if;
      if Handle >= Max_Open then
         Status := Status_Bad_Handle;
         return;
      end if;

      Find_Row (T, Badge, Row, Found);
      if not Found
        or else not Is_Open (T (Row).Opens (Open_Index (Handle)))
      then
         Status := Status_Bad_Handle;
         return;
      end if;

      T (Row).Opens (Open_Index (Handle)) := Closed;
      Status := Status_Ok;
   end Close;

   procedure Detach (T : in out Handle_Table; Badge : U64) is
      Row   : Client_Index;
      Found : Boolean;
   begin
      if Badge = 0 then
         return;
      end if;
      Find_Row (T, Badge, Row, Found);
      if Found then
         T (Row) := (Badge => 0, Opens => (others => Closed));
      end if;
   end Detach;

end Fs_Handles;
