using System.Data;
using System.Security.Claims;
using System.Text.Json;
using System.Text.RegularExpressions;
using static Database;
public static class VenueDirectoryEndpoints
{
 public static void MapVenueDirectory(this WebApplication app)
 {
  app.MapGet("/api/venues/search",async(string? q,int? subtypeId,Database db,CancellationToken ct)=>{
   if(q?.Length>100 || subtypeId is <=0) return Results.BadRequest(new{error="Use a search up to 100 characters and a valid activity."});
   return Results.Ok((await db.Call("dbo.SearchVenues",ct,P("@Query",SqlDbType.NVarChar,q?.Trim()??"",100),P("@SubtypeId",SqlDbType.Int,subtypeId)))[0]);
  }).RequireRateLimiting("browse");
  app.MapPost("/api/operator/venues",async(DirectoryVenue input,ClaimsPrincipal user,Database db,CancellationToken ct)=>{
   if(string.IsNullOrWhiteSpace(input.Name)||input.Name.Length>120||string.IsNullOrWhiteSpace(input.Area)||input.Area.Length>80||string.IsNullOrWhiteSpace(input.Address)||input.Address.Length>250
    ||input.Phone is null||!Regex.IsMatch(input.Phone,@"^\+[0-9]{7,15}$")||input.SubtypeIds is not {Length:>=1 and <=17}||input.SubtypeIds.Any(id=>id<=0))
    return Results.BadRequest(new{error="Provide the actual venue name, area, address, international phone and supported activities."});
   var id=int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
   var row=(await db.Call("dbo.AddDirectoryVenue",ct,P("@UserId",SqlDbType.Int,id),P("@Name",SqlDbType.NVarChar,input.Name.Trim(),120),
    P("@Area",SqlDbType.NVarChar,input.Area.Trim(),80),P("@Address",SqlDbType.NVarChar,input.Address.Trim(),250),P("@Phone",SqlDbType.VarChar,input.Phone,20),
    P("@SportsJson",SqlDbType.NVarChar,JsonSerializer.Serialize(input.SubtypeIds),2000),P("@Verified",SqlDbType.Bit,input.Verified)))[0][0];
   return Results.Ok(row);
  }).RequireAuthorization().RequireRateLimiting("checkout");
 }
}
public sealed record DirectoryVenue(string Name,string Area,string Address,string Phone,int[] SubtypeIds,bool Verified=false);
