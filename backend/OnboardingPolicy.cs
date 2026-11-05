public static class OnboardingPolicy
{
    public static readonly string[] Genders = ["Male", "Female", "NonBinary", "PreferNotToSay"];
    public static bool ValidBirth(DateOnly? birth, DateOnly today) => birth.HasValue && birth >= new DateOnly(1900,1,1) && birth <= today;
    public static bool ValidSports(int[]? sports) => sports is {Length:>=1 and <=3} && sports.All(id=>id>0) && sports.Distinct().Count()==sports.Length;
}
