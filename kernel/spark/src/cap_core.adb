--  SPDX-License-Identifier: GPL-3.0-or-later
package body Cap_Core with
  SPARK_Mode,
  Refined_State => (State => Store)
is
   Empty : constant Cap :=
     (Kind => None, Object => 0, Send => False, Recv => False, Grant => False);

   Store : Cap_Store := (others => (others => (None, 0, False, False, False)));

   function Snapshot return Cap_Store is (Store);

   function Valid_Rights (Rights : U64) return Boolean is (Rights <= 7);

   procedure Lemma_Witness (B : Cap_Store; C : Cap; P : Proc_Id; S : Slot_Id) with
     Ghost,
     Global => null,
     Pre    => Subsumes (B (P) (S), C),
     Post   => Is_Covered (C, B)
   is
   begin
      null;
   end Lemma_Witness;

   --  A solo difiere de B en una entrada, vacía o derivada de B (Q) (W).
   procedure Lemma_One_Copy
     (A, B : Cap_Store;
      P0   : Proc_Id;
      S0   : Slot_Id;
      Q    : Proc_Id;
      W    : Slot_Id)
   with
     Ghost,
     Global => null,
     Pre    =>
       (for all P in Proc_Id =>
          (for all S in Slot_Id =>
             (if P /= P0 or else S /= S0 then A (P) (S) = B (P) (S))))
       and then (A (P0) (S0).Kind = None or else Subsumes (B (Q) (W), A (P0) (S0))),
     Post   => Covered (A, B)
   is
   begin
      for P in Proc_Id loop
         for S in Slot_Id loop
            if A (P) (S).Kind /= None then
               if P = P0 and then S = S0 then
                  Lemma_Witness (B, A (P) (S), Q, W);
               else
                  Lemma_Witness (B, A (P) (S), P, S);
               end if;
            end if;
            pragma Loop_Invariant
              (for all T in Slot_Id => (if T <= S then Is_Covered (A (P) (T), B)));
         end loop;
         pragma Loop_Invariant
           (for all R in Proc_Id =>
              (if R <= P
               then (for all T in Slot_Id => Is_Covered (A (R) (T), B))));
      end loop;
   end Lemma_One_Copy;

   --  A solo difiere de B en entradas que han quedado vacías.
   procedure Lemma_Only_Removed (A, B : Cap_Store) with
     Ghost,
     Global => null,
     Pre    =>
       (for all P in Proc_Id =>
          (for all S in Slot_Id => A (P) (S) = B (P) (S) or else A (P) (S).Kind = None)),
     Post   => Covered (A, B)
   is
   begin
      for P in Proc_Id loop
         for S in Slot_Id loop
            if A (P) (S).Kind /= None then
               Lemma_Witness (B, A (P) (S), P, S);
            end if;
            pragma Loop_Invariant
              (for all T in Slot_Id => (if T <= S then Is_Covered (A (P) (T), B)));
         end loop;
         pragma Loop_Invariant
           (for all R in Proc_Id =>
              (if R <= P
               then (for all T in Slot_Id => Is_Covered (A (R) (T), B))));
      end loop;
   end Lemma_Only_Removed;

   --  Sin cambios: la autoridad queda como estaba.
   procedure Lemma_Unchanged (B : Cap_Store) with
     Ghost,
     Global => null,
     Post   => Covered (B, B)
   is
   begin
      Lemma_Only_Removed (B, B);
   end Lemma_Unchanged;

   function Grant
     (Proc, Slot, Kind, Object, Rights : U64) return U64
   is
   begin
      if not Valid_Proc (Proc)
        or else not Valid_Slot (Slot)
        or else not Valid_Kind (Kind)
        or else Object >= U64 (Max_Objects)
        or else not Valid_Rights (Rights)
      then
         return Status_Invalid;
      end if;

      if Store (Proc_Id (Proc)) (Slot_Id (Slot)).Kind /= None then
         return Status_Occupied;
      end if;

      Store (Proc_Id (Proc)) (Slot_Id (Slot)) :=
        (Kind   => Decode_Kind (Kind),
         Object => Object_Id (Object),
         Send   => (Rights and Right_Send) /= 0,
         Recv   => (Rights and Right_Recv) /= 0,
         Grant  => (Rights and Right_Grant) /= 0);
      return Status_Ok;
   end Grant;

   function Refers (Kind, Object : U64) return U64 is
   begin
      if not Valid_Kind (Kind) or else Object >= U64 (Max_Objects) then
         return 0;
      end if;
      for P in Proc_Id loop
         for S in Slot_Id loop
            if Store (P) (S).Kind = Decode_Kind (Kind)
              and then U64 (Store (P) (S).Object) = Object
            then
               return 1;
            end if;
            pragma Loop_Invariant
              (for all T in Slot_Id'First .. S =>
                 not (Store (P) (T).Kind = Decode_Kind (Kind)
                      and then U64 (Store (P) (T).Object) = Object));
         end loop;
         pragma Loop_Invariant
           (for all Q in Proc_Id'First .. P =>
              (for all T in Slot_Id =>
                 not (Store (Q) (T).Kind = Decode_Kind (Kind)
                      and then U64 (Store (Q) (T).Object) = Object)));
      end loop;
      return 0;
   end Refers;

   function Check (Proc, Slot, Kind, Right : U64) return U64 is
   begin
      if not Valid_Proc (Proc)
        or else not Valid_Slot (Slot)
        or else not Valid_Kind (Kind)
      then
         return No_Object;
      end if;

      declare
         C : constant Cap := Store (Proc_Id (Proc)) (Slot_Id (Slot));
      begin
         if C.Kind /= Decode_Kind (Kind) or else not Has_Right (C, Right) then
            return No_Object;
         end if;
         return U64 (C.Object);
      end;
   end Check;

   function Holds_Receive (Proc, Object : U64) return U64 is
   begin
      if not Valid_Proc (Proc) then
         return 0;
      end if;

      for S in Slot_Id loop
         if Can_Receive (Store (Proc_Id (Proc)) (S), Object) then
            return 1;
         end if;
      end loop;
      return 0;
   end Holds_Receive;

   function Other_Receiver (Proc, Object : U64) return U64 is
   begin
      if not Valid_Proc (Proc) then
         return 1;
      end if;

      for Q in Proc_Id loop
         pragma Loop_Invariant
           (for all P in Proc_Id =>
              (if P < Q and then P /= Proc_Id (Proc)
               then (for all S in Slot_Id => not Can_Receive (Store (P) (S), Object))));

         if Q /= Proc_Id (Proc) then
            for S in Slot_Id loop
               pragma Loop_Invariant
                 (for all X in Slot_Id =>
                    (if X < S then not Can_Receive (Store (Q) (X), Object)));

               if Can_Receive (Store (Q) (S), Object) then
                  return 1;
               end if;
            end loop;
         end if;
      end loop;
      return 0;
   end Other_Receiver;

   function Held (Proc, Slot : U64) return U64 is
   begin
      if not Valid_Proc (Proc) or else not Valid_Slot (Slot) then
         return 0;
      end if;
      return (if Store (Proc_Id (Proc)) (Slot_Id (Slot)).Kind = None then 0 else 1);
   end Held;

   function Derive (Proc, Src, Dst, Rights : U64) return U64 is
      Old : constant Cap_Store := Store with Ghost;
   begin
      Lemma_Unchanged (Old);

      if not Valid_Proc (Proc)
        or else not Valid_Slot (Src)
        or else not Valid_Slot (Dst)
        or else not Valid_Rights (Rights)
      then
         return Status_Invalid;
      end if;

      declare
         P      : constant Proc_Id := Proc_Id (Proc);
         From   : constant Cap := Store (P) (Slot_Id (Src));
         Copy   : constant Cap :=
           (Kind   => From.Kind,
            Object => From.Object,
            Send   => (Rights and Right_Send) /= 0,
            Recv   => (Rights and Right_Recv) /= 0,
            Grant  => (Rights and Right_Grant) /= 0);
      begin
         if From.Kind = None
           or else (Copy.Send and then not From.Send)
           or else (Copy.Recv and then not From.Recv)
           or else (Copy.Grant and then not From.Grant)
         then
            return Status_Denied;
         end if;

         if Store (P) (Slot_Id (Dst)).Kind /= None then
            return Status_Occupied;
         end if;

         Store (P) (Slot_Id (Dst)) := Copy;
         Lemma_One_Copy (Store, Old, P, Slot_Id (Dst), P, Slot_Id (Src));
      end;
      return Status_Ok;
   end Derive;

   function Transfer (From_Proc, From_Slot, To_Proc, To_Slot : U64) return U64 is
      Old : constant Cap_Store := Store with Ghost;
   begin
      Lemma_Unchanged (Old);

      if not Valid_Proc (From_Proc)
        or else not Valid_Proc (To_Proc)
        or else not Valid_Slot (From_Slot)
        or else not Valid_Slot (To_Slot)
      then
         return Status_Invalid;
      end if;

      if Store (Proc_Id (From_Proc)) (Slot_Id (From_Slot)).Kind = None then
         return Status_Denied;
      end if;

      if Store (Proc_Id (To_Proc)) (Slot_Id (To_Slot)).Kind /= None then
         return Status_Occupied;
      end if;

      Store (Proc_Id (To_Proc)) (Slot_Id (To_Slot)) :=
        Store (Proc_Id (From_Proc)) (Slot_Id (From_Slot));
      Lemma_One_Copy
        (Store, Old,
         Proc_Id (To_Proc), Slot_Id (To_Slot),
         Proc_Id (From_Proc), Slot_Id (From_Slot));
      return Status_Ok;
   end Transfer;

   function Delete (Proc, Slot : U64) return U64 is
      Old : constant Cap_Store := Store with Ghost;
   begin
      Lemma_Unchanged (Old);

      if not Valid_Proc (Proc) or else not Valid_Slot (Slot) then
         return Status_Invalid;
      end if;

      if Store (Proc_Id (Proc)) (Slot_Id (Slot)).Kind = None then
         return Status_Denied;
      end if;

      Store (Proc_Id (Proc)) (Slot_Id (Slot)) := Empty;
      Lemma_Only_Removed (Store, Old);
      return Status_Ok;
   end Delete;

   function Clear (Proc : U64) return U64 is
      Old : constant Cap_Store := Store with Ghost;
   begin
      Lemma_Unchanged (Old);

      if not Valid_Proc (Proc) then
         return Status_Invalid;
      end if;

      Store (Proc_Id (Proc)) := (others => Empty);
      Lemma_Only_Removed (Store, Old);
      return Status_Ok;
   end Clear;

end Cap_Core;
