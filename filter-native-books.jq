# A migrated book has one Notion writer: Readest. Match its exact Kobo ID.
if ($owned | type) != "array" or
   ($owned | all(.[]; type == "string" and length > 0) | not) then
  error("Readest ownership must be an array of nonempty Kobo volume IDs")
else
  map(select(.volumeId as $id | $owned | index($id) | not))
end
